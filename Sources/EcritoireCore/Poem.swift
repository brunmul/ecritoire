import Foundation

/// Format « poème » : un verset par paragraphe, préfixé de sa position entre crochets (`[12] Texte…`).
///
/// Le numéro n'est pas du texte : il sert de référence (« v. 12 », « v. 9–11 ») et se recalcule d'après
/// la position du verset. Ce qui précède le premier verset (titre `# …`, ligne de révision, note) est
/// l'en-tête du poème, clos par une ligne `---` ; il n'est jamais renuméroté.
public enum Poem {
    public struct Verse: Equatable, Sendable {
        /// Position du verset (1, 2, 3…), recalculée d'après l'ordre des paragraphes.
        public let number: Int
        /// Paragraphe entier, sans le retour à la ligne final.
        public let range: NSRange
        /// Marqueur `[n] ` (nil si le verset n'en a pas encore, par exemple juste après Retour).
        public let marker: NSRange?
        /// Texte du verset, sans le marqueur.
        public let text: String
    }

    /// `[n] ` en début de paragraphe ; `[n](…)` est un lien (renvoi de note), pas un numéro de verset.
    static let markerRE = try! NSRegularExpression(pattern: #"^\[(\d{1,4})\](?!\()[ \t]?"#)
    static let innerMarkerRE = try! NSRegularExpression(pattern: #"\[\d{1,4}\](?!\()[ \t]?"#)
    static let ruleRE = try! NSRegularExpression(pattern: #"^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#)

    /// Marqueur `[n] ` au début d'une ligne (plage relative à la ligne) et son numéro.
    public static func marker(in line: String) -> (range: NSRange, number: Int)? {
        let ns = line as NSString
        guard let m = markerRE.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let n = Int(ns.substring(with: m.range(at: 1))) else { return nil }
        return (m.range, n)
    }

    public static func isRule(_ line: String) -> Bool {
        ruleRE.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// Vrai si le texte suit le format des versets numérotés (au moins deux paragraphes `[n]`).
    public static func isPoem(_ text: String) -> Bool {
        var count = 0
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { line, _, _, stop in
            if let line, marker(in: line) != nil { count += 1; if count >= 2 { stop.pointee = true } }
        }
        return count >= 2
    }

    /// Fin de l'en-tête du poème : après la ligne `---` qui précède le premier verset numéroté, sinon au premier verset.
    /// 0 s'il n'y a ni verset numéroté ni séparateur.
    public static func headerEnd(in text: NSString) -> Int {
        var ruleEnd: Int?
        var result = 0
        var found = false
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { line, range, enclosing, stop in
            guard let line else { return }
            if marker(in: line) != nil {
                result = ruleEnd ?? range.location
                found = true
                stop.pointee = true
            } else if isRule(line) {
                ruleEnd = NSMaxRange(enclosing)
            }
        }
        return found ? result : (ruleEnd ?? 0)
    }

    /// Versets du texte (paragraphes non vides après l'en-tête), numérotés d'après leur position.
    public static func verses(in text: String) -> [Verse] {
        let ns = text as NSString
        let start = headerEnd(in: ns)
        guard start < ns.length else { return [] }
        var out: [Verse] = []
        ns.enumerateSubstrings(in: NSRange(location: start, length: ns.length - start), options: .byParagraphs) { line, range, _, _ in
            guard let line, !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let m = marker(in: line)
            let markerRange = m.map { NSRange(location: range.location + $0.range.location, length: $0.range.length) }
            let body = m.map { (line as NSString).substring(from: NSMaxRange($0.range)) } ?? line
            out.append(Verse(number: out.count + 1, range: range, marker: markerRange, text: body))
        }
        return out
    }

    /// Remplacements qui renumérotent les versets d'après leur position : marqueurs recalés, marqueur ajouté
    /// aux nouveaux versets, marqueurs restés au milieu d'un verset (après une fusion) retirés, ligne blanche
    /// rétablie entre deux versets collés. Triés de la fin vers le début (à appliquer dans cet ordre).
    public static func renumberEdits(_ text: String) -> [(range: NSRange, replacement: String)] {
        let ns = text as NSString
        guard isPoem(text) else { return [] }
        var edits: [(NSRange, String)] = []
        var previousVerseEnd: Int?
        for verse in verses(in: text) {
            let wanted = "[\(verse.number)] "
            // Deux versets sans ligne blanche entre eux : on rétablit l'espace.
            let glued = previousVerseEnd.map { verse.range.location == $0 + 1 } ?? false
            if let marker = verse.marker {
                if ns.substring(with: marker) != wanted { edits.append((marker, wanted)) }
                if glued { edits.append((NSRange(location: verse.range.location, length: 0), "\n")) }
            } else {
                edits.append((NSRange(location: verse.range.location, length: 0), (glued ? "\n" : "") + wanted))
            }
            // Marqueurs au milieu du verset (deux versets fusionnés) : remplacés par une espace si besoin.
            let contentStart = verse.marker.map(NSMaxRange) ?? verse.range.location
            let content = NSRange(location: contentStart, length: NSMaxRange(verse.range) - contentStart)
            for m in innerMarkerRE.matches(in: text, range: content).reversed() {
                let before = m.range.location > 0 ? ns.character(at: m.range.location - 1) : 0x20
                let needsSpace = !(before == 0x20 || before == 0x09) && m.range.location > content.location
                edits.append((m.range, needsSpace ? " " : ""))
            }
            previousVerseEnd = NSMaxRange(verse.range)
        }
        return edits.sorted { $0.0.location > $1.0.location || ($0.0.location == $1.0.location && $0.0.length > $1.0.length) }
    }

    /// Texte renuméroté (mêmes règles que `renumberEdits`).
    public static func renumbered(_ text: String) -> String {
        let out = NSMutableString(string: text)
        for edit in renumberEdits(text) { out.replaceCharacters(in: edit.range, with: edit.replacement) }
        return out as String
    }

    /// Référence des versets touchés par une plage : « v. 12 », « v. 9–11 » (nil hors des versets).
    public static func reference(for range: NSRange, in text: String) -> String? {
        let touched = verses(in: text).filter {
            NSIntersectionRange($0.range, range).length > 0 || NSLocationInRange(range.location, $0.range)
        }
        guard let first = touched.first?.number, let last = touched.last?.number else { return nil }
        return first == last ? "v. \(first)" : "v. \(first)–\(last)"
    }

    /// Premiers mots d'un verset (pour le sommaire).
    public static func incipit(_ text: String, words: Int = 6) -> String {
        let parts = text.split(whereSeparator: \.isWhitespace)
        let head = parts.prefix(words).joined(separator: " ")
        return parts.count > words ? head + "…" : head
    }
}

/// Affichage choisi pour chaque document (« prose » ou « poeme »), dans `.ecritoire/affichage.json`,
/// jamais dans le fichier Markdown.
extension Sidecar {
    public enum Display: String, Sendable { case prose, poeme }

    static func displayFile(in root: URL) -> URL {
        root.appendingPathComponent(folderName).appendingPathComponent("affichage.json")
    }

    public static func display(for document: URL, in root: URL) -> Display? {
        guard let relative = relativePath(of: document, in: root),
              let data = try? Data(contentsOf: displayFile(in: root)),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return map[relative].flatMap(Display.init(rawValue:))
    }

    public static func setDisplay(_ display: Display?, for document: URL, in root: URL) throws {
        guard let relative = relativePath(of: document, in: root) else { return }
        let file = displayFile(in: root)
        var map = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        map[relative] = display?.rawValue
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(map).write(to: file, options: .atomic)
    }
}
