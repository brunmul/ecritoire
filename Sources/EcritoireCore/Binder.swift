import Foundation

/// Un élément du classeur : un dossier ou un document `.md`.
/// Sous-classe de NSObject pour servir directement d'élément à NSOutlineView.
public final class BinderNode: NSObject {
    public let url: URL
    public let isFolder: Bool
    public internal(set) var children: [BinderNode] = []
    /// Icône choisie (identifiant du catalogue de l'app), nil = icône par défaut.
    public internal(set) var icon: String?
    public internal(set) weak var parent: BinderNode?

    init(url: URL, isFolder: Bool) {
        self.url = url
        self.isFolder = isFolder
    }

    /// Nom affiché : le nom du fichier sans l'extension `.md`.
    public var displayName: String {
        isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    public func find(_ target: URL) -> BinderNode? {
        if Binder.samePath(url, target) { return self }
        for child in children {
            if let hit = child.find(target) { return hit }
        }
        return nil
    }

    public var allDescendants: [BinderNode] {
        children.flatMap { [$0] + $0.allDescendants }
    }
}

public enum BinderError: LocalizedError {
    case invalidName
    case alreadyExists(String)
    case moveIntoItself

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Ce nom n'est pas valide."
        case .alreadyExists(let name): return "« \(name) » existe déjà à cet endroit."
        case .moveIntoItself: return "Impossible de déplacer un dossier dans lui-même."
        }
    }
}

/// Opérations sur un dossier « classeur » : lecture de l'arbre, ordre manuel, création, renommage, déplacement.
///
/// L'ordre manuel d'un dossier est stocké dans un fichier texte `.order` à l'intérieur de ce dossier,
/// un nom de fichier par ligne. Les éléments absents du fichier sont ajoutés à la fin, triés par nom,
/// ce qui rend le format tolérant aux fichiers créés par d'autres outils.
public enum Binder {
    public static let orderFileName = ".order"
    /// Icônes personnalisées des éléments d'un dossier : une ligne « nom<TAB>icône » par élément.
    public static let iconsFileName = ".icones"
    public static let documentExtension = "md"

    // MARK: Lecture

    public static func loadTree(at root: URL) -> BinderNode {
        let node = BinderNode(url: root, isFolder: true)
        fill(node)
        return node
    }

    private static func fill(_ folder: BinderNode) {
        let icons = readIcons(in: folder.url)
        folder.children = orderedEntries(in: folder.url).map { url in
            let isDir = isDirectory(url)
            let child = BinderNode(url: url, isFolder: isDir)
            child.icon = icons[url.lastPathComponent]
            child.parent = folder
            if isDir { fill(child) }
            return child
        }
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Dossiers et fichiers .md visibles d'un dossier, dans l'ordre manuel.
    public static func orderedEntries(in folder: URL) -> [URL] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        let visible = contents.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isPackage == true { return false }
            if values?.isDirectory == true { return true }
            return url.pathExtension.lowercased() == documentExtension
        }
        let byName = Dictionary(visible.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [URL] = []
        var used = Set<String>()
        for name in readOrder(in: folder) where !used.contains(name) {
            if let url = byName[name] {
                result.append(url)
                used.insert(name)
            }
        }
        let rest = visible.filter { !used.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return result + rest
    }

    public static func readOrder(in folder: URL) -> [String] {
        let url = folder.appendingPathComponent(orderFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func writeOrder(_ names: [String], in folder: URL) throws {
        let url = folder.appendingPathComponent(orderFileName)
        try (names.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Insère `name` dans l'ordre du dossier à la position `index` (nil ou hors bornes : à la fin).
    static func insertInOrder(_ name: String, in folder: URL, at index: Int?) throws {
        var names = orderedEntries(in: folder).map(\.lastPathComponent).filter { $0 != name }
        let position = min(max(index ?? names.count, 0), names.count)
        names.insert(name, at: position)
        try writeOrder(names, in: folder)
    }

    static func removeFromOrder(_ name: String, in folder: URL) throws {
        let names = readOrder(in: folder)
        guard names.contains(name) else { return }
        try writeOrder(names.filter { $0 != name }, in: folder)
    }

    static func replaceInOrder(_ old: String, with new: String, in folder: URL) throws {
        // Appelé après le renommage sur le disque : on se base sur le fichier .order, pas sur le contenu du dossier.
        var names = readOrder(in: folder)
        guard let i = names.firstIndex(of: old) else { return }
        names[i] = new
        var seen = Set<String>()
        names = names.filter { seen.insert($0).inserted }
        try writeOrder(names, in: folder)
    }

    // MARK: Création

    public static func uniqueURL(in folder: URL, base: String, ext: String?) -> URL {
        let fm = FileManager.default
        func make(_ n: String) -> URL {
            let u = folder.appendingPathComponent(n)
            return ext.map { u.appendingPathExtension($0) } ?? u
        }
        var candidate = make(base)
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(i)")
            i += 1
        }
        return candidate
    }

    @discardableResult
    public static func createDocument(in folder: URL, named base: String = "Sans titre", at index: Int? = nil) throws -> URL {
        let url = uniqueURL(in: folder, base: base, ext: documentExtension)
        let doc = MarkdownDocument(title: url.deletingPathExtension().lastPathComponent)
        try doc.serialized().write(to: url, atomically: true, encoding: .utf8)
        try insertInOrder(url.lastPathComponent, in: folder, at: index)
        return url
    }

    @discardableResult
    public static func createFolder(in folder: URL, named base: String = "Nouveau dossier", at index: Int? = nil) throws -> URL {
        let url = uniqueURL(in: folder, base: base, ext: nil)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try insertInOrder(url.lastPathComponent, in: folder, at: index)
        return url
    }

    // MARK: Renommage, déplacement, corbeille

    /// Renomme un élément. Pour un document, `.md` est ajouté automatiquement.
    @discardableResult
    public static func rename(_ url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix("."), !trimmed.contains(":") else {
            throw BinderError.invalidName
        }
        let folder = url.deletingLastPathComponent()
        let isDir = isDirectory(url)
        var target = folder.appendingPathComponent(trimmed)
        if !isDir && target.pathExtension.lowercased() != documentExtension {
            target = target.appendingPathExtension(documentExtension)
        }
        if target.lastPathComponent == url.lastPathComponent { return url }
        let caseOnly = target.lastPathComponent.lowercased() == url.lastPathComponent.lowercased()
        if !caseOnly && FileManager.default.fileExists(atPath: target.path) {
            throw BinderError.alreadyExists(target.lastPathComponent)
        }
        if caseOnly {
            // Sur un volume insensible à la casse, on passe par un nom temporaire.
            let temp = folder.appendingPathComponent(".renommage-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: temp)
            try FileManager.default.moveItem(at: temp, to: target)
        } else {
            try FileManager.default.moveItem(at: url, to: target)
        }
        try replaceInOrder(url.lastPathComponent, with: target.lastPathComponent, in: folder)
        var icons = readIcons(in: folder)
        if let icon = icons.removeValue(forKey: url.lastPathComponent) {
            icons[target.lastPathComponent] = icon
            try writeIcons(icons, in: folder)
        }
        return target
    }

    /// Déplace `url` dans `destination` à la position `index` (index dans l'ordre affiché de la destination,
    /// tel que le propose NSOutlineView ; nil ou -1 : à la fin). Gère aussi le simple réordonnancement.
    @discardableResult
    public static func move(_ url: URL, into destination: URL, at index: Int?) throws -> URL {
        let source = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let index = (index ?? -1) < 0 ? nil : index

        if samePath(source, destination) {
            var names = orderedEntries(in: destination).map(\.lastPathComponent)
            guard let old = names.firstIndex(of: name) else { return url }
            names.remove(at: old)
            var position = names.count
            if let index { position = index > old ? index - 1 : index }
            names.insert(name, at: min(max(position, 0), names.count))
            try writeOrder(names, in: destination)
            return url
        }

        let destPath = destination.standardizedFileURL.resolvingSymlinksInPath().path
        let srcPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        if destPath == srcPath || destPath.hasPrefix(srcPath + "/") { throw BinderError.moveIntoItself }

        let target = destination.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { throw BinderError.alreadyExists(name) }
        try FileManager.default.moveItem(at: url, to: target)
        try removeFromOrder(name, in: source)
        try insertInOrder(name, in: destination, at: index)
        var sourceIcons = readIcons(in: source)
        if let icon = sourceIcons.removeValue(forKey: name) {
            try writeIcons(sourceIcons, in: source)
            var destIcons = readIcons(in: destination)
            destIcons[name] = icon
            try writeIcons(destIcons, in: destination)
        }
        return target
    }

    public static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        try removeFromOrder(url.lastPathComponent, in: url.deletingLastPathComponent())
    }

    // MARK: Icônes

    public static func readIcons(in folder: URL) -> [String: String] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(iconsFileName), encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "\t")
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { out[parts[0]] = parts[1] }
        }
        return out
    }

    public static func writeIcons(_ icons: [String: String], in folder: URL) throws {
        let url = folder.appendingPathComponent(iconsFileName)
        if icons.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let text = icons.keys.sorted().map { "\($0)\t\(icons[$0]!)" }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Change l'icône d'un document ou d'un dossier (nil : icône par défaut).
    public static func setIcon(_ icon: String?, for url: URL) throws {
        let folder = url.deletingLastPathComponent()
        var icons = readIcons(in: folder)
        icons[url.lastPathComponent] = icon
        try writeIcons(icons, in: folder)
    }

    public static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
