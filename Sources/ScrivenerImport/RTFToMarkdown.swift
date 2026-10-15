import AppKit

/// Conversion RTF (tel que Scrivener l'écrit) → Markdown.
///
/// Scrivener balise ses styles dans le texte même : `<$Scr_Ps::N>…<!$Scr_Ps::N>` pour un style de paragraphe
/// (N = position dans content.styles) et `<$Scr_H::N>` pour un titre de niveau N. Un style peut couvrir
/// plusieurs paragraphes : on suit donc un état d'un paragraphe à l'autre.
struct RTFToMarkdown {
    struct ExtractedImage {
        let data: Data
        let ext: String
    }

    /// Nom du style Scrivener pour chaque index `<$Scr_Ps::N>`.
    let styleNames: [String]

    private static let scrivenerTag = try! NSRegularExpression(pattern: #"<(!?)\$Scr([A-Za-z_]*)(?:::(\d+))?>"#)
    private static let listMarker = try! NSRegularExpression(pattern: #"^\t?[^\t\n]{0,8}\t"#)
    private static let imagePlaceholder = try! NSRegularExpression(pattern: RTFImageExtractor.placeholderPattern)

    enum Block { case normal, heading(Int), quote, intro, caption }

    func convert(_ url: URL, saveImage: (Int, ExtractedImage) throws -> String) throws -> String {
        let raw = try Data(contentsOf: url)
        if raw.isEmpty { return "" }
        let (data, pictures) = RTFImageExtractor.extract(from: raw)
        let attributed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                documentAttributes: nil)
        return try convert(attributed, pictures: pictures, saveImage: saveImage)
    }

    func convert(_ text: NSAttributedString, pictures: [RTFImageExtractor.Picture?] = [],
                 saveImage: (Int, ExtractedImage) throws -> String) throws -> String {
        let string = text.string as NSString
        var paragraphs: [String] = []
        var imageCount = 0
        var location = 0
        var paragraphStyle: Int? = nil   // <$Scr_Ps::N> en cours
        var headingLevel: Int? = nil     // <$Scr_H::N> en cours

        func storeImage(_ image: ExtractedImage) -> String {
            imageCount += 1
            guard let name = try? saveImage(imageCount, image), !name.isEmpty else { return "" }
            return "![[\(name)]]"
        }

        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            var content = range
            while content.length > 0, let scalar = UnicodeScalar(string.character(at: NSMaxRange(content) - 1)),
                  CharacterSet.newlines.contains(scalar) || scalar == "\u{2029}" {
                content.length -= 1
            }
            let raw = string.substring(with: content) as NSString

            // Balises Scrivener : celles qui précèdent le texte fixent le style de ce paragraphe,
            // les suivantes ne valent que pour les paragraphes d'après.
            var styleForThis: (Int?, Int?)? = nil
            var lastEnd = 0
            for match in Self.scrivenerTag.matches(in: raw as String, range: NSRange(location: 0, length: raw.length)) {
                let before = raw.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                if styleForThis == nil, !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    styleForThis = (paragraphStyle, headingLevel)
                }
                lastEnd = NSMaxRange(match.range)
                let closing = raw.substring(with: match.range(at: 1)) == "!"
                let kind = raw.substring(with: match.range(at: 2))
                let number = match.range(at: 3).location != NSNotFound ? Int(raw.substring(with: match.range(at: 3))) : nil
                switch kind {
                case "_Ps": paragraphStyle = closing ? (paragraphStyle == number ? nil : paragraphStyle) : number
                case "_H": headingLevel = closing ? (headingLevel == number ? nil : headingLevel) : number
                default: break
                }
            }
            let (psIndex, hLevel) = styleForThis ?? (paragraphStyle, headingLevel)
            let styleName = psIndex.flatMap { $0 < styleNames.count ? styleNames[$0].lowercased() : nil } ?? ""
            let block = Self.block(styleName: styleName, headingLevel: hLevel)
            var isHeading = false
            if case .heading = block { isHeading = true }

            let style = content.length > 0 ? text.attribute(.paragraphStyle, at: content.location, effectiveRange: nil) as? NSParagraphStyle : nil
            let lists = style?.textLists ?? []

            // Contenu en ligne : gras, italique, liens, images.
            var line = ""
            var pending: (text: String, bold: Bool, italic: Bool, link: String?)? = nil
            func flush() {
                guard let p = pending else { return }
                line += Self.wrap(p.text, bold: p.bold && !isHeading, italic: p.italic && !isHeading, link: p.link)
                pending = nil
            }
            text.enumerateAttributes(in: content, options: []) { attrs, runRange, _ in
                if let attachment = attrs[.attachment] as? NSTextAttachment {
                    flush()
                    if let image = Self.imageData(attachment) { line += "\n\n" + storeImage(image) + "\n\n" }
                    return
                }
                var piece = string.substring(with: runRange).replacingOccurrences(of: "\u{FFFC}", with: "")
                piece = piece.replacingOccurrences(of: "\u{2028}", with: "  \n")
                let font = attrs[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                let bold = traits.contains(.boldFontMask)
                let italic = traits.contains(.italicFontMask) || (attrs[.obliqueness] as? CGFloat ?? 0) > 0
                var link: String?
                if let url = attrs[.link] as? URL { link = url.absoluteString } else if let s = attrs[.link] as? String { link = s }
                if let p = pending, p.bold == bold, p.italic == italic, p.link == link {
                    pending!.text += piece
                } else {
                    flush()
                    pending = (piece, bold, italic, link)
                }
            }
            flush()

            line = Self.scrivenerTag.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
            // Images \pict extraites du RTF : chacune sur son propre paragraphe.
            if line.contains("ECRITOIREIMAGE") {
                let ns = line as NSString
                var rebuilt = ""
                var last = 0
                for m in Self.imagePlaceholder.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    rebuilt += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                    last = NSMaxRange(m.range)
                    let index = Int(ns.substring(with: m.range(at: 1))) ?? -1
                    if index >= 0, index < pictures.count, let pic = pictures[index] {
                        rebuilt += "\n\n" + storeImage(ExtractedImage(data: pic.data, ext: pic.ext)) + "\n\n"
                    }
                }
                rebuilt += ns.substring(from: last)
                line = rebuilt
            }
            if !lists.isEmpty {
                line = Self.listMarker.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
            }

            // Un paragraphe peut maintenant contenir des images isolées : on traite chaque morceau.
            for piece in line.components(separatedBy: "\n\n") {
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if trimmed.hasPrefix("![[") && trimmed.hasSuffix("]]") {
                    paragraphs.append(trimmed)
                    continue
                }
                switch block {
                case .heading(let level):
                    let plain = trimmed.replacingOccurrences(of: "  \n", with: " ")
                    paragraphs.append(String(repeating: "#", count: level) + " " + plain)
                case .quote:
                    paragraphs.append(trimmed.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n"))
                case .intro:
                    // Chapeau : encadré (callout) « intro », compris par Obsidian et Quartz.
                    // Les paragraphes d'intro consécutifs vont dans le même encadré.
                    let lines = trimmed.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
                    if let last = paragraphs.last, last.hasPrefix("> [!intro]") {
                        paragraphs[paragraphs.count - 1] = last + "\n>\n" + lines
                    } else {
                        paragraphs.append("> [!intro]\n" + lines)
                    }
                case .caption:
                    paragraphs.append(Self.wrap(trimmed, bold: false, italic: true, link: nil))
                case .normal:
                    if !lists.isEmpty {
                        let depth = lists.count - 1
                        let ordered = lists.last.map { !["{disc}", "{circle}", "{square}", "{hyphen}", "{check}"].contains($0.markerFormat.rawValue) } ?? false
                        let item = String(repeating: "    ", count: depth) + (ordered ? "1. " : "- ") + trimmed
                        if let last = paragraphs.last, last.hasPrefix("- ") || last.hasPrefix("1. ") || last.hasPrefix("    ") {
                            paragraphs[paragraphs.count - 1] = last + "\n" + item
                        } else {
                            paragraphs.append(item)
                        }
                    } else {
                        paragraphs.append(Self.escapeLineStart(trimmed))
                    }
                }
            }
        }
        return paragraphs.isEmpty ? "" : paragraphs.joined(separator: "\n\n") + "\n"
    }

    // MARK: Styles

    static func block(styleName: String, headingLevel: Int?) -> Block {
        if let headingLevel, headingLevel > 0 { return .heading(min(headingLevel, 6)) }
        if styleName == "intro" || styleName.contains("chapeau") || styleName.contains("lead") { return .intro }
        if let level = Self.headingLevel(styleName) { return .heading(level) }
        let quoteWords = ["citation", "quote", "poésie", "verse", "bloc"]
        if quoteWords.contains(where: { styleName.contains($0) }) && !styleName.contains("code") { return .quote }
        if styleName.contains("caption") || styleName.contains("légende") || styleName.contains("attribution") { return .caption }
        return .normal
    }

    /// « Title »/« Titre » = 1, « Heading 2 »/« Titre 2 » = 2, « Vedette 1 » (convention française de Scrivener) = 2.
    static func headingLevel(_ style: String) -> Int? {
        guard !style.isEmpty else { return nil }
        let digit = style.first(where: { $0.isNumber }).flatMap { Int(String($0)) }
        if style.contains("vedette") { return min((digit ?? 1) + 1, 6) }
        let isHeading = ["titre", "heading", "überschrift", "title", "intertitre"].contains { style.contains($0) }
        guard isHeading else { return nil }
        if let digit { return min(max(digit, 1), 6) }
        // « Title » sans numéro sert d'intertitre dans les textes (sous les titres de niveau 1 et 2).
        if style == "title" { return 3 }
        return style.contains("sous") ? 2 : 1
    }

    // MARK: Utilitaires

    /// Entoure un segment de marqueurs Markdown en laissant les espaces de bord à l'extérieur.
    static func wrap(_ text: String, bold: Bool, italic: Bool, link: String?) -> String {
        let escaped = text.replacingOccurrences(of: "*", with: "\\*")
        guard bold || italic || link != nil else { return escaped }
        let core = escaped.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return escaped }
        let lead = String(escaped.prefix(while: { $0 == " " || $0 == "\t" }))
        let trail = String(escaped.reversed().prefix(while: { $0 == " " || $0 == "\t" }))
        let marker = bold && italic ? "***" : bold ? "**" : italic ? "*" : ""
        var inner = marker + core + marker
        if let link { inner = "[\(inner)](\(link.replacingOccurrences(of: " ", with: "%20")))" }
        return lead + inner + trail
    }

    /// Évite qu'un paragraphe ordinaire soit lu comme un titre ou une liste.
    static func escapeLineStart(_ line: String) -> String {
        if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("- ") || line.hasPrefix("+ ") { return "\\" + line }
        return line
    }

    static func imageData(_ attachment: NSTextAttachment) -> ExtractedImage? {
        if let wrapper = attachment.fileWrapper, let data = wrapper.regularFileContents {
            let ext = (wrapper.preferredFilename as NSString?)?.pathExtension.lowercased() ?? ""
            if ["png", "jpg", "jpeg", "gif", "tiff", "tif", "pdf", "heic", "webp"].contains(ext) {
                return ExtractedImage(data: data, ext: ext == "tif" ? "tiff" : ext)
            }
            if let image = NSImage(data: data), let png = pngData(image) { return ExtractedImage(data: png, ext: "png") }
        }
        if let image = attachment.image, let png = pngData(image) { return ExtractedImage(data: png, ext: "png") }
        return nil
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
