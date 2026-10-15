import AppKit
import EcritoireCore

/// Export PDF fidèle à la page d'Écritoire : même mise en forme (MarkdownHighlighter) et mêmes fragments de dessin
/// (citations à filet, images, séparateurs ondulés, en-tête de poème) que l'éditeur, en mode clair, sans les signes
/// Markdown. Format A4, colonne aux proportions de l'éditeur, numéros de page ; coupure de page entre deux lignes,
/// jamais un titre seul en bas de page.
@MainActor
enum PDFExport {
    static let pageSize = CGSize(width: 595.28, height: 841.89) // A4
    /// Corps du texte imprimé ; la colonne garde les proportions de l'éditeur (600 pt pour 19 pt, 540 pour un poème).
    static let fontSize: CGFloat = 12.5
    static var proseColumn: CGFloat { (fontSize * MarkdownEditor.baseColumnWidth / MarkdownEditor.baseFontSize).rounded() }
    static var poemColumn: CGFloat { (fontSize * MarkdownEditor.basePoemColumnWidth / MarkdownEditor.baseFontSize).rounded() }
    static let topMargin: CGFloat = 70
    static let bottomMargin: CGFloat = 76
    /// Ligne de base des numéros de page, depuis le bas de la feuille.
    static let folioBaseline: CGFloat = 40

    /// Une section mise en page : texte TextKit 2 et boîtes de lignes (coordonnées de la section).
    private final class Laid {
        let layout: NSTextLayoutManager
        let content: NSTextContentStorage
        let highlighter: MarkdownHighlighter
        let fragments: FragmentProvider
        let column: CGFloat
        var height: CGFloat = 0
        var boxes: [Box] = []
        var offset: CGFloat = 0
        init(layout: NSTextLayoutManager, content: NSTextContentStorage, highlighter: MarkdownHighlighter,
             fragments: FragmentProvider, column: CGFloat) {
            self.layout = layout; self.content = content; self.highlighter = highlighter; self.fragments = fragments; self.column = column
        }
    }

    /// Une ligne (ou une image) insécable ; `keepWithNext` pour les titres.
    private struct Box {
        var top: CGFloat
        var bottom: CGFloat
        var keepWithNext: Bool
    }

    /// Nombre de pages du dernier rendu (pour les vérifications).
    private(set) static var lastPageCount = 0

    static func render(_ sections: [Export.Section], title: String) -> Data {
        var data = Data()
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            data = renderLight(sections, title: title)
        }
        return data
    }

    private static func renderLight(_ sections: [Export.Section], title: String) -> Data {
        // 1. Mise en page de chaque section, empilées.
        var laid: [Laid] = []
        var y: CGFloat = 0
        for section in sections {
            let l = layout(section)
            l.offset = y
            y += l.height + fontSize * 1.5
            laid.append(l)
        }
        // 2. Pages : fenêtres verticales de l'empilement, coupées entre deux boîtes.
        let boxes = laid.flatMap { l in l.boxes.map { Box(top: $0.top + l.offset, bottom: $0.bottom + l.offset, keepWithNext: $0.keepWithNext) } }
        let pages = paginate(boxes)
        lastPageCount = pages.count
        // 3. Dessin.
        let out = NSMutableData()
        var media = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Écritoire"]
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, info as CFDictionary) else { return Data() }
        for (index, page) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            for l in laid where l.offset < page.end && l.offset + l.height > page.start {
                let x = ((pageSize.width - l.column) / 2).rounded()
                l.layout.enumerateTextLayoutFragments(from: l.layout.documentRange.location, options: [.ensuresLayout]) { fragment in
                    let frame = fragment.layoutFragmentFrame
                    let top = l.offset + frame.minY
                    if top - 40 > page.end { return false }
                    if top + frame.height + 40 < page.start { return true }
                    let origin = CGPoint(x: x + frame.minX, y: topMargin + top - page.start)
                    let lines = fragment.textLineFragments.filter { $0.typographicBounds.height > 2 }
                    let inside = { (line: NSTextLineFragment) -> Bool in
                        top + line.typographicBounds.minY >= page.start - 0.5 && top + line.typographicBounds.maxY <= page.end + 0.5
                    }
                    if lines.allSatisfy(inside) {
                        // Paragraphe entier sur la page : dessiné par son fragment (filet, image, séparateur…).
                        if lines.isEmpty && (top + frame.height < page.start || top > page.end) { return true }
                        fragment.draw(at: origin, in: ctx)
                    } else {
                        // Paragraphe coupé entre deux pages : seulement ses lignes de cette page (le texte du PDF
                        // ne doit pas contenir les lignes de la page voisine), et le filet d'une citation.
                        let shown = lines.filter(inside)
                        for line in shown {
                            line.draw(at: CGPoint(x: origin.x + line.typographicBounds.minX, y: origin.y + line.typographicBounds.minY), in: ctx)
                        }
                        let paragraph = (fragment.textElement as? NSTextParagraph)?.attributedString
                        if let first = shown.first, let last = shown.last, let paragraph, paragraph.length > 0,
                           (paragraph.attribute(.ecritoireBlock, at: 0, effectiveRange: nil) as? String) == "citation" {
                            let left = shown.map(\.typographicBounds.minX).min() ?? 0
                            let bar = CGRect(x: origin.x + left - fontSize * 0.7, y: origin.y + first.typographicBounds.minY + 2,
                                             width: 2.5, height: last.typographicBounds.maxY - first.typographicBounds.minY - 4)
                            ctx.setFillColor(NSColor.quaternaryLabelColor.cgColor)
                            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 1.25, cornerHeight: 1.25, transform: nil))
                            ctx.fillPath()
                        }
                    }
                    return true
                }
            }
            drawFolio(index + 1)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    // MARK: Mise en page d'une section

    private static func layout(_ section: Export.Section) -> Laid {
        var text = Export.text(of: section)
        if section.poem { text = Export.removeVerseNumbers(text) }
        let column = section.poem ? poemColumn : proseColumn
        let highlighter = MarkdownHighlighter()
        highlighter.fontSize = fontSize
        highlighter.columnWidth = column
        highlighter.maxImageHeight = pageSize.height - topMargin - bottomMargin - fontSize * 3
        highlighter.poemMode = section.poem
        let folder = section.isFolder ? section.source : section.source.deletingLastPathComponent()
        var cache: [String: NSImage] = [:]
        highlighter.imageProvider = { name in
            if let image = cache[name] { return image }
            let file = (name.components(separatedBy: "|").first ?? name).trimmingCharacters(in: .whitespaces)
            let image = NSImage(contentsOf: folder.appendingPathComponent(file))
            cache[name] = image
            return image
        }
        // Séparateur ondulé avant chaque partie, comme dans l'éditeur (le titre de la section n'en est pas une).
        let headings = headingLines(text).dropFirst()
        highlighter.partLevel = headings.map(\.level).min() ?? 1
        highlighter.firstHeadingLocation = headings.first?.location

        let storage = NSTextStorage(string: text)
        highlighter.highlightAll(storage)
        for h in headingLines(text) {
            storage.addAttribute(.ecritoireExportHeading, value: true, range: (text as NSString).paragraphRange(for: NSRange(location: h.location, length: 0)))
        }
        removeHiddenText(storage)

        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        let fragments = FragmentProvider()
        fragments.highlighter = highlighter
        layout.delegate = fragments
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: column, height: 0))
        container.lineFragmentPadding = 0
        layout.textContainer = container
        content.attributedString = storage
        layout.ensureLayout(for: layout.documentRange)

        let laid = Laid(layout: layout, content: content, highlighter: highlighter, fragments: fragments, column: column)
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            laid.height = max(laid.height, frame.maxY)
            let paragraph = (fragment.textElement as? NSTextParagraph)?.attributedString
            let attrs = paragraph.flatMap { $0.length > 0 ? $0.attributes(at: 0, effectiveRange: nil) : nil } ?? [:]
            let heading = attrs[.ecritoireExportHeading] != nil
            var first = true
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds
                guard bounds.height > 2 || attrs[.ecritoireImage] != nil || attrs[.ecritoireOrnament] != nil else { continue }
                var top = frame.minY + bounds.minY
                if first {
                    // Ce qui se dessine au-dessus de la première ligne reste avec elle : image, séparateur ondulé.
                    if let image = attrs[.ecritoireImage] as? NSImage { top -= highlighter.displaySize(image).height + 10 }
                    if let space = attrs[.ecritoireSeparator] as? CGFloat { top -= space * 0.75 }
                }
                laid.boxes.append(Box(top: top, bottom: frame.minY + bounds.maxY, keepWithNext: heading))
                first = false
            }
            return true
        }
        return laid
    }

    /// Titres `#` du texte : position et niveau.
    private static func headingLines(_ text: String) -> [(location: Int, level: Int)] {
        var out: [(Int, Int)] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { line, range, _, _ in
            guard let line, let m = line.range(of: #"^#{1,6}[ \t]"#, options: .regularExpression) else { return }
            out.append((range.location, line[m].filter { $0 == "#" }.count))
        }
        return out
    }

    /// Retire les signes masqués (`**`, `# `, `> `, lignes vides…) : le PDF ne contient que le texte lu,
    /// et le copier-coller depuis le PDF ne ramène pas de Markdown. Une image ou un ornement garde un caractère
    /// invisible pour conserver son paragraphe.
    private static func removeHiddenText(_ storage: NSTextStorage) {
        var hidden: [NSRange] = []
        let ns = storage.string as NSString
        // Par paragraphe : deux paragraphes masqués voisins (ligne vide, ornement) ne doivent pas se confondre.
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, _, para, _ in
            storage.enumerateAttribute(.font, in: para) { value, range, _ in
                if let font = value as? NSFont, font.pointSize < 0.1 { hidden.append(range) }
            }
        }
        storage.beginEditing()
        for range in hidden.reversed() {
            let attrs = storage.attributes(at: range.location, effectiveRange: nil)
            if attrs[.ecritoireImage] != nil || attrs[.ecritoireOrnament] != nil {
                let keepNewline = range.length > 0 && ns.character(at: NSMaxRange(range) - 1) == 0x0A
                let inner = NSRange(location: range.location, length: range.length - (keepNewline ? 1 : 0))
                if inner.length > 0 { storage.replaceCharacters(in: inner, with: "\u{200B}") }
            } else {
                storage.deleteCharacters(in: range)
            }
        }
        storage.endEditing()
    }

    // MARK: Pages

    private static func paginate(_ boxes: [Box]) -> [(start: CGFloat, end: CGFloat)] {
        let available = pageSize.height - topMargin - bottomMargin
        guard !boxes.isEmpty else { return [(0, available)] }
        var pages: [(CGFloat, CGFloat)] = []
        var first = 0
        var i = 0
        while i < boxes.count {
            let start = boxes[first].top
            if boxes[i].bottom - start > available && i > first {
                // Coupure avant la boîte i ; un titre ne reste jamais seul en bas de page.
                var cut = i
                while cut - 1 > first && boxes[cut - 1].keepWithNext { cut -= 1 }
                pages.append((start, boxes[cut].top))
                first = cut
                i = cut
                continue
            }
            i += 1
        }
        let start = boxes[first].top
        pages.append((start, max(boxes.last!.bottom, start) + 1))
        return pages
    }

    /// Numéro de page centré en bas : Walbaum Grotesk, gris.
    private static func drawFolio(_ number: Int) {
        let font = EditorTheme(size: fontSize).font(.grotesk, 0.72)
        let label = NSAttributedString(string: "\(number)", attributes: [.font: font, .foregroundColor: Palette.secondaryText])
        let size = label.size()
        label.draw(at: CGPoint(x: ((pageSize.width - size.width) / 2).rounded(),
                               y: pageSize.height - folioBaseline - font.ascender))
    }

    // MARK: Fichiers

    /// Écrit le PDF de `sections` à `destination`.
    static func write(_ sections: [Export.Section], title: String, to destination: URL) throws {
        try render(sections, title: title).write(to: destination, options: .atomic)
    }
}

extension NSAttributedString.Key {
    /// Paragraphe de titre (export PDF : jamais seul en bas de page).
    static let ecritoireExportHeading = NSAttributedString.Key("ecritoireExportHeading")
}
