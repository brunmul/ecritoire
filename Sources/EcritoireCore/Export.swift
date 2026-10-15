import Foundation

/// Export d'un document ou d'un dossier du classeur (Markdown propre, ou matière du PDF).
///
/// Un dossier donne un seul texte : ses documents dans l'ordre du classeur (`.order`), chacun précédé de son titre
/// en intertitre (un niveau de plus par profondeur), les titres internes décalés d'autant. Les fichiers sources ne
/// sont jamais modifiés : tout est lu, transformé en mémoire, puis écrit à la destination choisie.
public enum Export {
    /// Une section : un dossier (titre seul) ou un document (titre et texte).
    public struct Section: Equatable, Sendable {
        /// Titre affiché (titre de l'en-tête, à défaut premier titre du texte, à défaut nom du fichier).
        public var title: String
        /// Niveau de l'intertitre : 1 pour l'élément exporté, puis +1 par dossier traversé (6 au plus).
        public var level: Int
        /// Texte sans en-tête YAML ni titre en double ; vide pour un dossier.
        public var body: String
        /// Affichage « poème » (en-tête centré, versets sans leurs numéros).
        public var poem: Bool
        public var isFolder: Bool
        /// Fichier ou dossier source (les images `![[…]]` sont cherchées à côté).
        public var source: URL
    }

    // MARK: Lecture

    /// Sections à exporter pour `url` (document ou dossier), dans l'ordre du classeur.
    public static func sections(for url: URL, root: URL?) -> [Section] {
        var out: [Section] = []
        collect(url, depth: 0, root: root, into: &out)
        return out
    }

    private static func collect(_ url: URL, depth: Int, root: URL?, into out: inout [Section]) {
        let level = min(depth + 1, 6)
        if Binder.isDirectory(url) {
            out.append(Section(title: url.lastPathComponent, level: level, body: "", poem: false, isFolder: true, source: url))
            for child in Binder.orderedEntries(in: url) {
                if Binder.isDirectory(child) || child.pathExtension.lowercased() == "md" {
                    collect(child, depth: depth + 1, root: root, into: &out)
                }
            }
            return
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        out.append(section(text: text, url: url, level: level, root: root))
    }

    /// Section d'un document : titre, texte nettoyé de l'en-tête et du titre en double, affichage.
    public static func section(text: String, url: URL, level: Int, root: URL?) -> Section {
        let stem = url.deletingPathExtension().lastPathComponent
        let hasFrontmatter = text.hasPrefix("---\n") || text.hasPrefix("---\r\n")
        let doc = MarkdownDocument.parse(text, defaultTitle: stem)
        var title = doc.title.trimmingCharacters(in: .whitespaces)
        var body = doc.body
        // Sans en-tête YAML (un poème, une note), le premier titre du texte est le titre du document.
        if !hasFrontmatter || title.isEmpty, let first = firstHeading(in: body) { title = first }
        if title.isEmpty { title = stem }
        if let duplicate = TitleMatch.duplicatedTitle(in: body, title: title) {
            body = (body as NSString).replacingCharacters(in: duplicate, with: "")
        }
        body = body.trimmingCharacters(in: .newlines)
        let numbering = Poem.isPoem(body)
        var poem = numbering
        if let root {
            if let chosen = Sidecar.display(for: url, in: root) { poem = chosen == .poeme }
            else if TitleMatch.normalize(root.lastPathComponent).hasPrefix("poeme") { poem = true }
        }
        return Section(title: title, level: level, body: body, poem: poem, isFolder: false, source: url)
    }

    static func firstHeading(in body: String) -> String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            guard t.hasPrefix("#") else { return nil }
            let title = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }

    // MARK: Texte de chaque section (commun au Markdown et au PDF)

    /// Texte d'une section prêt à mettre en page : intertitre, titres internes décalés, sans commentaires
    /// `%% … %%` ni `<!-- … -->`, sans surligneurs. Les numéros `[n]` des versets restent (le PDF les masque,
    /// le Markdown les retire) ; les images restent en `![[…]]` (le Markdown les convertit).
    public static func text(of section: Section) -> String {
        let heading = String(repeating: "#", count: section.level) + " " + section.title
        if section.isFolder { return heading }
        var body = removeComments(section.body)
        body = removeHighlights(body)
        body = shiftHeadings(body, by: section.level - 1)
        return body.isEmpty ? heading : heading + "\n\n" + body
    }

    static let commentRE = try! NSRegularExpression(pattern: #"%%[\s\S]*?%%|<!--[\s\S]*?-->"#)
    static let highlightRE = try! NSRegularExpression(pattern: #"(?<!=)==(?=[^\s=])(.+?)(?<=[^\s=])==(?!=)"#)
    static let markRE = try! NSRegularExpression(pattern: #"<mark class="[a-zA-Zéè-]+">(.+?)</mark>"#)
    static let headingRE = try! NSRegularExpression(pattern: #"^(#{1,6})(?=[ \t])"#, options: .anchorsMatchLines)
    static let imageRE = try! NSRegularExpression(pattern: #"!\[\[([^\]\n|]+)(?:\|[^\]\n]*)?\]\]"#)
    static let wikiRE = try! NSRegularExpression(pattern: #"(?<!!)\[\[([^\]\n|]+)(?:\|([^\]\n]+))?\]\]"#)
    static let verseRE = try! NSRegularExpression(pattern: #"^\[\d{1,4}\](?!\()[ \t]?"#, options: .anchorsMatchLines)

    /// Commentaires internes retirés ; une ligne qui ne contenait qu'un commentaire disparaît avec son blanc.
    public static func removeComments(_ text: String) -> String {
        let out = replace(commentRE, in: text) { _ in "" }
        return out.replacingOccurrences(of: #"\n[ \t]*\n(?:[ \t]*\n)+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .newlines)
    }

    public static func removeHighlights(_ text: String) -> String {
        let plain = replace(highlightRE, in: text) { $0[1] }
        return replace(markRE, in: plain) { $0[1] }
    }

    /// Décale les titres `#` de `by` niveaux (6 au plus), pour qu'ils restent sous l'intertitre du document.
    public static func shiftHeadings(_ text: String, by delta: Int) -> String {
        guard delta > 0 else { return text }
        return replace(headingRE, in: text) { String(repeating: "#", count: min(6, $0[1].count + delta)) }
    }

    /// Versets sans leur numéro `[n] ` (le numéro n'est pas du texte).
    public static func removeVerseNumbers(_ text: String) -> String {
        replace(verseRE, in: text) { _ in "" }
    }

    // MARK: Markdown

    /// Image à copier à côté du fichier exporté.
    public struct ImageCopy: Equatable, Sendable {
        public let source: URL
        public let name: String
    }

    /// Markdown standard de toutes les sections ; `![[image]]` devient `![image](nom)` et l'image est à copier.
    /// Les liens internes `[[cible|libellé]]` deviennent leur libellé.
    public static func markdown(_ sections: [Section]) -> (text: String, images: [ImageCopy]) {
        var images: [ImageCopy] = []
        var used = Set<String>()
        var parts: [String] = []
        for section in sections {
            var text = Self.text(of: section)
            if section.poem { text = removeVerseNumbers(text) }
            let folder = section.isFolder ? section.source : section.source.deletingLastPathComponent()
            text = replace(imageRE, in: text) { m in
                let name = m[1].trimmingCharacters(in: .whitespaces)
                let source = folder.appendingPathComponent(name)
                let alt = (name as NSString).deletingPathExtension
                guard FileManager.default.fileExists(atPath: source.path) else { return "![\(alt)](\(encode(name)))" }
                if let existing = images.first(where: { $0.source.standardizedFileURL == source.standardizedFileURL }) {
                    return "![\(alt)](\(encode(existing.name)))"
                }
                let unique = uniqueName(name, used: &used)
                images.append(ImageCopy(source: source, name: unique))
                return "![\(alt)](\(encode(unique)))"
            }
            text = replace(wikiRE, in: text) { m in m.count > 2 && !m[2].isEmpty ? m[2] : m[1] }
            parts.append(text)
        }
        return (parts.joined(separator: "\n\n") + "\n", images)
    }

    /// Écrit le Markdown et copie les images à côté ; renvoie les fichiers écrits.
    @discardableResult
    public static func writeMarkdown(_ sections: [Section], to destination: URL) throws -> [URL] {
        let (text, images) = markdown(sections)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        var written = [destination]
        let folder = destination.deletingLastPathComponent()
        for image in images {
            let target = folder.appendingPathComponent(image.name)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: image.source, to: target)
            written.append(target)
        }
        return written
    }

    static func encode(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))) ?? name
    }

    static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name
        var i = 2
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            i += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// Remplacement par expression régulière ; `make` reçoit le texte des groupes (0 = tout).
    static func replace(_ re: NSRegularExpression, in text: String, _ make: ([String]) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += make(groups)
            last = NSMaxRange(m.range)
        }
        out += ns.substring(from: last)
        return out
    }
}
