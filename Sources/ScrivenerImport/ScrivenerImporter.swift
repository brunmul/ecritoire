import AppKit
import EcritoireCore

/// Convertit un projet Scrivener 3 (`.scriv`) en classeur Écritoire, sans modifier l'original.
///
/// - l'arborescence et l'ordre du classeur Scrivener sont conservés (fichiers `.order`) ;
/// - un dossier, ou un texte qui a des enfants, devient un dossier ; s'il contient du texte,
///   celui-ci est placé dans un document du même nom, en tête du dossier ;
/// - le RTF devient du Markdown : titres (styles Scrivener), citations, listes, gras, italique, liens, images ;
/// - synopsis, statut, étiquette, notes et dates sont reportés dans l'en-tête ou en commentaire `%% %%` ;
/// - la corbeille Scrivener n'est pas importée.
public final class ScrivenerImporter {
    public struct Report {
        public var destination: URL
        public var documents = 0
        public var folders = 0
        public var files = 0
        public var warnings: [String] = []
    }

    public enum ImportError: LocalizedError {
        case notAProject(String)
        case alreadyExists(String)

        public var errorDescription: String? {
            switch self {
            case .notAProject(let s): return "« \(s) » n'est pas un projet Scrivener 3 lisible."
            case .alreadyExists(let s): return "Le dossier « \(s) » existe déjà : supprimez-le ou choisissez une autre destination."
            }
        }
    }

    let project: URL
    let dataFolder: URL
    private let xml: XMLDocument
    private var labels: [String: String] = [:]
    private var statuses: [String: String] = [:]
    private var keywords: [String: String] = [:]
    private var styleNames: [String: String] = [:]
    private var report: Report
    /// Icônes à écrire, par dossier (fichier .icones).
    private var icons: [URL: [String: String]] = [:]
    public var progress: ((Int) -> Void)?

    public init(project: URL, destinationFolder: URL) throws {
        self.project = project
        dataFolder = project.appendingPathComponent("Files/Data")
        let fm = FileManager.default
        guard let scrivx = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "scrivx" }),
              fm.fileExists(atPath: dataFolder.path),
              let doc = try? XMLDocument(contentsOf: scrivx) else {
            throw ImportError.notAProject(project.lastPathComponent)
        }
        xml = doc
        let name = project.deletingPathExtension().lastPathComponent
        report = Report(destination: destinationFolder.appendingPathComponent(Self.safeName(name)))
        readSettings()
    }

    public static func defaultDestination() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Classeurs")
    }

    // MARK: Réglages du projet

    private func readSettings() {
        func table(_ path: String) -> [String: String] {
            var out: [String: String] = [:]
            for node in (try? xml.nodes(forXPath: path)) ?? [] {
                guard let el = node as? XMLElement, let id = el.attribute(forName: "ID")?.stringValue else { continue }
                out[id] = el.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return out
        }
        labels = table("/ScrivenerProject/LabelSettings/Labels/Label")
        statuses = table("/ScrivenerProject/StatusSettings/StatusItems/Status")
        keywords = table("/ScrivenerProject/Keywords//Keyword")
        // Styles : l'index utilisé dans le RTF (<$Scr_Ps::N>) renvoie à la ligne N de content.styles,
        // qui contient l'identifiant d'un style défini dans Files/styles.xml.
        if let styles = try? XMLDocument(contentsOf: project.appendingPathComponent("Files/styles.xml")) {
            for node in (try? styles.nodes(forXPath: "//Style")) ?? [] {
                guard let el = node as? XMLElement, let id = el.attribute(forName: "ID")?.stringValue,
                      let name = el.attribute(forName: "Name")?.stringValue else { continue }
                styleNames[id] = name
            }
        }
    }

    // MARK: Import

    public func run() throws -> Report {
        let fm = FileManager.default
        if fm.fileExists(atPath: report.destination.path) {
            throw ImportError.alreadyExists(report.destination.path)
        }
        try fm.createDirectory(at: report.destination, withIntermediateDirectories: true)
        let top = ((try? xml.nodes(forXPath: "/ScrivenerProject/Binder/BinderItem")) ?? []).compactMap { $0 as? XMLElement }
        var names: [String] = []
        var used = Set<String>()
        for item in top where item.attribute(forName: "Type")?.stringValue != "TrashFolder" {
            if let name = try importItem(item, into: report.destination, used: &used) { names.append(contentsOf: name) }
        }
        try Binder.writeOrder(names, in: report.destination)
        for (folder, map) in icons { try Binder.writeIcons(map, in: folder) }
        return report
    }

    /// Importe un élément et renvoie le ou les noms créés dans `folder` (dans l'ordre).
    private func importItem(_ item: XMLElement, into folder: URL, used: inout Set<String>) throws -> [String]? {
        let type = item.attribute(forName: "Type")?.stringValue ?? "Text"
        let uuid = item.attribute(forName: "UUID")?.stringValue ?? ""
        let title = item.elements(forName: "Title").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let children = item.elements(forName: "Children").first?.elements(forName: "BinderItem") ?? []
        let isContainer = !children.isEmpty || ["Folder", "DraftFolder", "ResearchFolder"].contains(type)
        let base = Self.safeName(title.isEmpty ? "Sans titre" : title)
        let itemData = dataFolder.appendingPathComponent(uuid)

        if isContainer {
            let name = unique(base, ext: nil, used: &used)
            let dir = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            report.folders += 1
            var inner = Set<String>()
            var order: [String] = []
            // Texte propre au dossier, s'il y en a : un document du même nom en tête.
            if let doc = try writeDocument(item, title: title, base: base, data: itemData, in: dir, used: &inner, skipIfEmpty: true) {
                order.append(contentsOf: doc)
            }
            for child in children {
                if let created = try importItem(child, into: dir, used: &inner) { order.append(contentsOf: created) }
            }
            try Binder.writeOrder(order, in: dir)
            setDates(item, on: dir)
            recordIcon(item, type: type, name: name, in: folder)
            return [name]
        }
        let created = try writeDocument(item, title: title, base: base, data: itemData, in: folder, used: &used, skipIfEmpty: false)
        if let name = created?.first { recordIcon(item, type: type, name: name, in: folder) }
        return created
    }

    private func writeDocument(_ item: XMLElement, title: String, base: String, data: URL, in folder: URL,
                               used: inout Set<String>, skipIfEmpty: Bool) throws -> [String]? {
        let fm = FileManager.default
        let mdName = unique(base, ext: "md", used: &used)
        let stem = (mdName as NSString).deletingPathExtension
        var body = ""
        var created: [String] = []

        let contentFiles = (try? fm.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []
        if let rtf = contentFiles.first(where: { $0.lastPathComponent == "content.rtf" }) {
            let styles = (try? String(contentsOf: data.appendingPathComponent("content.styles"), encoding: .utf8))?
                .components(separatedBy: CharacterSet(charactersIn: ",\n\r")) ?? []
            let converter = RTFToMarkdown(styleNames: styles.map { styleNames[$0.trimmingCharacters(in: .whitespaces)] ?? "" })
            do {
                body = try converter.convert(rtf) { index, image in
                    let imageName = "\(stem) - image \(index).\(image.ext)"
                    try image.data.write(to: folder.appendingPathComponent(imageName))
                    self.report.files += 1
                    return imageName
                }
            } catch {
                report.warnings.append("\(title) : texte illisible (\(error.localizedDescription))")
            }
        } else if let file = contentFiles.first(where: { $0.lastPathComponent.hasPrefix("content.") && $0.pathExtension != "styles" }) {
            // Image, PDF, page web… : copiés à côté d'un document qui les intègre.
            let fileName = unique(base, ext: file.pathExtension.lowercased(), used: &used)
            try fm.copyItem(at: file, to: folder.appendingPathComponent(fileName))
            report.files += 1
            body = "![[\(fileName)]]\n"
        }

        let synopsis = (try? String(contentsOf: data.appendingPathComponent("synopsis.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notesURL = data.appendingPathComponent("notes.rtf")
        var notes = ""
        if fm.fileExists(atPath: notesURL.path) {
            notes = ((try? RTFToMarkdown(styleNames: []).convert(notesURL) { _, _ in "" }) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if skipIfEmpty && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && synopsis.isEmpty && notes.isEmpty {
            used.remove(mdName.lowercased())
            return nil
        }
        if !notes.isEmpty {
            body = body.trimmingCharacters(in: .newlines) + "\n\n%% Notes Scrivener :\n" + notes.replacingOccurrences(of: "%%", with: "%") + "\n%%\n"
        }

        let meta = item.elements(forName: "MetaData").first
        func metaValue(_ key: String) -> String? { meta?.elements(forName: key).first?.stringValue }
        var extra: [String] = []
        if let label = metaValue("LabelID").flatMap({ labels[$0] }), metaValue("LabelID") != "-1" {
            extra.append("label: \(Self.quote(label))")
        }
        let tags = (item.elements(forName: "Keywords").first?.elements(forName: "KeywordID") ?? [])
            .compactMap { $0.stringValue.flatMap { keywords[$0] } }
        if !tags.isEmpty { extra.append("tags: [" + tags.map(Self.quote).joined(separator: ", ") + "]") }
        if let createdDate = item.attribute(forName: "Created")?.stringValue { extra.append("created: \(Self.quote(createdDate))") }
        if let modified = item.attribute(forName: "Modified")?.stringValue { extra.append("modified: \(Self.quote(modified))") }

        var status = DocumentStatus.brouillon.rawValue
        if let id = metaValue("StatusID"), id != "-1", let name = statuses[id] { status = Self.mapStatus(name) }

        let doc = MarkdownDocument(title: title.isEmpty ? "Sans titre" : title, synopsis: synopsis, status: status,
                                   publish: false, body: body, extraLines: extra)
        let url = folder.appendingPathComponent(mdName)
        try doc.serialized().write(to: url, atomically: true, encoding: .utf8)
        setDates(item, on: url)
        report.documents += 1
        progress?(report.documents)
        created.append(mdName)
        return created
    }

    // MARK: Utilitaires

    private func setDates(_ item: XMLElement, on url: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var attributes: [FileAttributeKey: Any] = [:]
        if let s = item.attribute(forName: "Modified")?.stringValue, let d = formatter.date(from: s) { attributes[.modificationDate] = d }
        if let s = item.attribute(forName: "Created")?.stringValue, let d = formatter.date(from: s) { attributes[.creationDate] = d }
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    private func unique(_ base: String, ext: String?, used: inout Set<String>) -> String {
        func make(_ n: String) -> String { ext.map { "\(n).\($0)" } ?? n }
        var name = make(base)
        var i = 2
        while used.contains(name.lowercased()) {
            name = make("\(base) \(i)")
            i += 1
        }
        used.insert(name.lowercased())
        return name
    }

    static func safeName(_ title: String) -> String {
        var s = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: #"\s*:\s*"#, with: " - ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 120 { s = String(s.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? "Sans titre" : s
    }

    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func mapStatus(_ scrivener: String) -> String {
        switch scrivener.lowercased() {
        case "à faire", "to do": return DocumentStatus.idee.rawValue
        case "en cours", "in progress": return DocumentStatus.enCours.rawValue
        case "version préliminaire", "first draft": return DocumentStatus.brouillon.rawValue
        case "brouillon révisé", "brouillon final", "revised draft", "final draft": return DocumentStatus.relu.rawValue
        case "terminé", "done": return DocumentStatus.termine.rawValue
        default: return scrivener.lowercased()
        }
    }

    // MARK: Icônes

    private func recordIcon(_ item: XMLElement, type: String, name: String, in folder: URL) {
        let scrivenerName = item.elements(forName: "MetaData").first?.elements(forName: "IconFileName").first?.stringValue
        guard let id = Self.iconID(scrivenerName: scrivenerName, type: type) else { return }
        icons[folder, default: [:]][name] = id
    }

    /// Correspondance entre les icônes de Scrivener et le catalogue d'Écritoire.
    public static func iconID(scrivenerName: String?, type: String) -> String? {
        if let raw = scrivenerName?.lowercased() {
            let colors = ["red": "rouge", "yellow": "jaune", "green": "vert", "blue": "bleu", "orange": "orange",
                          "purple": "violet", "pink": "rose", "black": "noir", "brown": "brun", "white": "blanc"]
            if raw.contains("book") || raw.contains("notebook") {
                let color = colors.first { raw.contains($0.key) }?.value ?? "bleu"
                return "carnet-" + color
            }
            if raw.contains("notepad") || raw.contains("notes") { return "notes" }
            if raw.contains("test tube") || raw.contains("flask") { return "eprouvette" }
            if raw.contains("pencil") || raw.contains("pen") { return "crayon" }
            if raw.contains("map") || raw.contains("location") { return "carte" }
            if raw.contains("filing") || raw.contains("cabinet") || raw.contains("archive") { return "classeur" }
            if raw.contains("calendar") || raw.contains("date") { return "calendrier" }
            if raw.contains("front matter") || raw.contains("manuscript") { return "liminaire" }
            if raw.contains("film") || raw.contains("movie") || raw.contains("cinema") { return "pellicule" }
            if raw.contains("spiral") { return "spirale" }
            if raw.contains("character") || raw.contains("person") || raw.contains("people") { return "personnage" }
            if raw.contains("idea") || raw.contains("bulb") { return "idee" }
            if raw.contains("star") { return "etoile" }
            if raw.contains("flag") { return "drapeau" }
            if raw.contains("pin") { return "epingle" }
            if raw.contains("research") || raw.contains("magnif") { return "recherche" }
        }
        switch type {
        case "DraftFolder": return "manuscrit"
        case "ResearchFolder": return "recherche"
        default: return nil
        }
    }

    /// Reporte les icônes d'un projet Scrivener sur un classeur déjà importé (sans rien réimporter).
    /// Les éléments sont appariés par nom, niveau par niveau.
    public static func applyIcons(from project: URL, to classeur: URL) throws -> Int {
        guard let scrivx = (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "scrivx" }),
              let xml = try? XMLDocument(contentsOf: scrivx) else { throw ImportError.notAProject(project.lastPathComponent) }
        var applied = 0
        func walk(_ items: [XMLElement], in folder: URL) throws {
            let existing = Binder.orderedEntries(in: folder)
            var available = existing
            var map = Binder.readIcons(in: folder)
            var changed = false
            for item in items {
                let type = item.attribute(forName: "Type")?.stringValue ?? "Text"
                if type == "TrashFolder" { continue }
                let title = item.elements(forName: "Title").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let base = safeName(title.isEmpty ? "Sans titre" : title)
                guard let index = available.firstIndex(where: { $0.deletingPathExtension().lastPathComponent == base || $0.lastPathComponent == base }) else { continue }
                let match = available.remove(at: index)
                let scrivenerName = item.elements(forName: "MetaData").first?.elements(forName: "IconFileName").first?.stringValue
                if let id = iconID(scrivenerName: scrivenerName, type: type), map[match.lastPathComponent] == nil {
                    map[match.lastPathComponent] = id
                    changed = true
                    applied += 1
                }
                let children = item.elements(forName: "Children").first?.elements(forName: "BinderItem") ?? []
                if !children.isEmpty, Binder.isDirectory(match) { try walk(children, in: match) }
            }
            if changed { try Binder.writeIcons(map, in: folder) }
        }
        let top = ((try? xml.nodes(forXPath: "/ScrivenerProject/Binder/BinderItem")) ?? []).compactMap { $0 as? XMLElement }
        try walk(top, in: classeur)
        return applied
    }
}
