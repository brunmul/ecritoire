import Foundation

/// Un commentaire posé sur un passage d'un document, façon Figma.
///
/// Les commentaires vivent hors du texte, dans `<classeur>/.ecritoire/commentaires/<chemin du document>.json`.
/// Ils sont ancrés par le passage cité et quelques mots de contexte avant/après, ce qui leur permet
/// de retrouver leur place même si le fichier a été modifié par un autre programme.
public struct DocumentComment: Codable, Identifiable, Equatable, Sendable {
    public struct Reply: Codable, Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var text: String
        public var date = Date.nowToTheSecond
        public init(text: String) { self.text = text }
    }

    public var id = UUID()
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var text: String
    public var date = Date.nowToTheSecond
    public var resolved = false
    public var replies: [Reply] = []
    /// Date d'envoi à Claude (prompt) : le commentaire passe alors en archive.
    public var sent: Date? = nil

    /// Archivé : envoyé à Claude ou résolu. Il n'apparaît plus ni dans le texte ni dans le volet, sauf dans « Archives ».
    public var isArchived: Bool { resolved || sent != nil }

    public init(quote: String, prefix: String, suffix: String, text: String) {
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.text = text
    }
}

public enum CommentAnchor {
    public static let contextLength = 40

    /// Contexte avant/après un passage, pour l'ancrage.
    public static func context(of range: NSRange, in text: NSString) -> (prefix: String, suffix: String) {
        let start = max(0, range.location - contextLength)
        let end = min(text.length, NSMaxRange(range) + contextLength)
        return (text.substring(with: NSRange(location: start, length: range.location - start)),
                text.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range))))
    }

    /// Retrouve le passage cité : parmi ses occurrences, celle dont le contexte ressemble le plus à celui enregistré.
    /// À défaut (passage réécrit), cherche le contexte seul et renvoie un emplacement vide entre les deux.
    public static func locate(_ comment: DocumentComment, in text: NSString, near hint: Int? = nil) -> NSRange? {
        guard !comment.quote.isEmpty else { return nil }
        var best: (NSRange, Int)? = nil
        var search = NSRange(location: 0, length: text.length)
        var guardCount = 0
        while guardCount < 500 {
            guardCount += 1
            let found = text.range(of: comment.quote, options: [], range: search)
            guard found.location != NSNotFound else { break }
            let (p, s) = context(of: found, in: text)
            var score = commonSuffix(p, comment.prefix) + commonPrefix(s, comment.suffix)
            if let hint { score -= min(abs(found.location - hint) / 2000, 20) }
            if best == nil || score > best!.1 { best = (found, score) }
            let next = found.location + max(found.length, 1)
            guard next < text.length else { break }
            search = NSRange(location: next, length: text.length - next)
        }
        if let best { return best.0 }
        // Passage modifié : on se rabat sur le contexte, s'il est encore là.
        if comment.prefix.count >= 12 {
            let p = text.range(of: String(comment.prefix.suffix(24)))
            if p.location != NSNotFound { return NSRange(location: NSMaxRange(p), length: 0) }
        }
        return nil
    }

    private static func commonSuffix(_ a: String, _ b: String) -> Int {
        zip(a.reversed(), b.reversed()).prefix(while: { $0 == $1 }).count
    }

    private static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix(while: { $0 == $1 }).count
    }
}

/// Fichiers annexes d'un classeur, rangés dans le dossier caché `.ecritoire` (ignoré par la barre latérale).
public enum Sidecar {
    public static let folderName = ".ecritoire"

    public enum Kind: String {
        case commentaires, instantanes, prompts
    }

    public static func relativePath(of document: URL, in root: URL) -> String? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let docPath = document.standardizedFileURL.resolvingSymlinksInPath().path
        guard docPath.hasPrefix(rootPath + "/") else { return nil }
        return String(docPath.dropFirst(rootPath.count + 1))
    }

    /// `.ecritoire/commentaires/Partie 1/Chapitre.md.json`, `.ecritoire/instantanes/Partie 1/Chapitre.md`…
    public static func url(_ kind: Kind, for document: URL, in root: URL) -> URL? {
        guard let relative = relativePath(of: document, in: root) else { return nil }
        var url = root.appendingPathComponent(folderName).appendingPathComponent(kind.rawValue).appendingPathComponent(relative)
        if kind == .commentaires { url = url.appendingPathExtension("json") }
        return url
    }

    public static func loadComments(for document: URL, in root: URL) -> [DocumentComment] {
        guard let url = url(.commentaires, for: document, in: root), let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DocumentComment].self, from: data)) ?? []
    }

    public static func saveComments(_ comments: [DocumentComment], for document: URL, in root: URL) throws {
        guard let url = url(.commentaires, for: document, in: root) else { return }
        if comments.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(comments).write(to: url, options: .atomic)
    }

    public static func loadSnapshot(for document: URL, in root: URL) -> String? {
        guard let url = url(.instantanes, for: document, in: root) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public static func saveSnapshot(_ text: String?, for document: URL, in root: URL) throws {
        guard let url = url(.instantanes, for: document, in: root) else { return }
        guard let text else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Un document ou un dossier a été renommé/déplacé : ses commentaires et instantanés suivent.
    public static func relocate(from old: URL, to new: URL, in root: URL) {
        let fm = FileManager.default
        guard let oldRel = relativePath(of: old, in: root), let newRel = relativePath(of: new, in: root) else { return }
        let base = root.appendingPathComponent(folderName)
        for kind in [Kind.commentaires, .instantanes] {
            let dir = base.appendingPathComponent(kind.rawValue)
            var pairs = [(dir.appendingPathComponent(oldRel), dir.appendingPathComponent(newRel))]
            if kind == .commentaires {
                pairs.append((dir.appendingPathComponent(oldRel + ".json"), dir.appendingPathComponent(newRel + ".json")))
            }
            for (from, to) in pairs where fm.fileExists(atPath: from.path) {
                try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: from, to: to)
            }
        }
    }
}

extension Date {
    /// Date arrondie à la seconde (le format ISO 8601 du fichier n'en garde pas plus).
    static var nowToTheSecond: Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }
}
