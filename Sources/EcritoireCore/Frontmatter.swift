import Foundation

/// Statuts proposés dans l'inspecteur. La valeur est écrite telle quelle dans l'en-tête YAML.
public enum DocumentStatus: String, CaseIterable, Sendable {
    case idee = "idée"
    case brouillon = "brouillon"
    case enCours = "en cours"
    case relu = "relu"
    case termine = "terminé"
}

/// Un document Markdown découpé en en-tête YAML + corps.
///
/// Les clés reconnues suivent les conventions de Quartz (`title`, `publish`) pour que le classeur
/// puisse être publié plus tard sans conversion. Les autres clés sont conservées telles quelles,
/// dans leur ordre d'origine, pour ne rien perdre de ce qu'un autre outil (ou une IA) aurait écrit.
public struct MarkdownDocument: Equatable, Sendable {
    public var title: String
    public var synopsis: String
    public var status: String
    public var publish: Bool
    public var body: String
    /// Lignes d'en-tête non reconnues (clé + valeur brute, ou ligne de continuation).
    public var extraLines: [String]

    public init(title: String = "", synopsis: String = "", status: String = DocumentStatus.brouillon.rawValue,
                publish: Bool = false, body: String = "", extraLines: [String] = []) {
        self.title = title
        self.synopsis = synopsis
        self.status = status
        self.publish = publish
        self.body = body
        self.extraLines = extraLines
    }

    static let knownKeys: Set<String> = ["title", "synopsis", "status", "publish"]

    // MARK: Lecture

    public static func parse(_ text: String, defaultTitle: String = "") -> MarkdownDocument {
        var doc = MarkdownDocument(title: defaultTitle)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else {
            doc.body = normalized
            return doc
        }
        let lines = normalized.components(separatedBy: "\n")
        guard let end = lines.indices.dropFirst().first(where: { lines[$0] == "---" || lines[$0] == "..." }) else {
            doc.body = normalized
            return doc
        }
        var skippingContinuation = false
        for line in lines[1..<end] {
            if let (key, value) = splitKeyValue(line) {
                skippingContinuation = false
                switch key {
                case "title": doc.title = unquote(value)
                case "synopsis": doc.synopsis = unquote(value)
                case "status": doc.status = unquote(value)
                case "publish": doc.publish = ["true", "yes", "oui", "1"].contains(unquote(value).lowercased())
                default:
                    doc.extraLines.append(line)
                    continue
                }
                skippingContinuation = value.isEmpty
            } else if skippingContinuation {
                continue // valeur multiligne d'une clé reconnue : non gérée en v0.1
            } else {
                doc.extraLines.append(line)
            }
        }
        var body = lines[(end + 1)...].joined(separator: "\n")
        if body.hasPrefix("\n") { body.removeFirst() }
        doc.body = body
        return doc
    }

    /// Découpe `clé: valeur` pour une clé de premier niveau (sans indentation).
    static func splitKeyValue(_ line: String) -> (String, String)? {
        guard let first = line.first, !first.isWhitespace, first != "-", first != "#",
              let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" ") else { return nil }
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            var out = ""
            var escaping = false
            for ch in value.dropFirst().dropLast() {
                if escaping {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaping = false
                } else if ch == "\\" {
                    escaping = true
                } else {
                    out.append(ch)
                }
            }
            return out
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        // Commentaire YAML en fin de ligne
        if let hash = value.range(of: " #") { return String(value[..<hash.lowerBound]) }
        return value
    }

    // MARK: Écriture

    public func serialized() -> String {
        var out = "---\n"
        out += "title: \(Self.quote(title))\n"
        out += "synopsis: \(Self.quote(synopsis))\n"
        out += "status: \(Self.quote(status))\n"
        out += "publish: \(publish ? "true" : "false")\n"
        for line in extraLines { out += line + "\n" }
        out += "---\n\n"
        out += body
        return out
    }

    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}

public enum WordCounter {
    /// Compte les mots : suites de caractères séparées par des blancs et contenant au moins une lettre ou un chiffre.
    /// « l'arbre » compte pour un mot, « — » pour zéro.
    public static func count(_ text: String) -> Int {
        var count = 0
        var inWord = false
        var hasAlnum = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if inWord && hasAlnum { count += 1 }
                inWord = false
                hasAlnum = false
            } else {
                inWord = true
                if CharacterSet.alphanumerics.contains(scalar) { hasAlnum = true }
            }
        }
        if inWord && hasAlnum { count += 1 }
        return count
    }
}

public enum TitleMatch {
    /// Forme comparable d'un titre : sans accents, casse, ponctuation ni numérotation de tête (« 01. », « 3 »).
    public static func normalize(_ title: String) -> String {
        var s = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        s = s.replacingOccurrences(of: #"^[\d.\s]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Si le texte commence par un titre identique au titre du document, sa position (paragraphe à masquer).
    public static func duplicatedTitle(in body: String, title: String) -> NSRange? {
        let ns = body as NSString
        var location = 0
        while location < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let line = ns.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { location = NSMaxRange(para); continue }
            guard line.hasPrefix("#") else { return nil }
            let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            let wanted = normalize(title)
            return !wanted.isEmpty && normalize(text) == wanted ? para : nil
        }
        return nil
    }
}
