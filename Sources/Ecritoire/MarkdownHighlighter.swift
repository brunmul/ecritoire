import AppKit
import EcritoireCore

extension NSAttributedString.Key {
    /// Image à dessiner au-dessus d'un paragraphe `![[…]]` (lue par ImageLayoutFragment).
    static let ecritoireImage = NSAttributedString.Key("ecritoireImage")
    /// Type de bloc du paragraphe (« citation », « intro ») pour le dessin du fond.
    static let ecritoireBlock = NSAttributedString.Key("ecritoireBlock")
    /// Couleur de surlignage (`==…==` ou `<mark class="…">…</mark>`), dessinée par RichLayoutFragment.
    static let ecritoireHighlight = NSAttributedString.Key("ecritoireHighlight")
    /// Passage commenté (valeur : CommentMark) et pastille posée sur son premier caractère.
    static let ecritoireComment = NSAttributedString.Key("ecritoireComment")
    static let ecritoireCommentPin = NSAttributedString.Key("ecritoireCommentPin")
    /// Texte ajouté ou supprimé en mode « Modifications » (valeur : DiffMark).
    static let ecritoireDiff = NSAttributedString.Key("ecritoireDiff")
    /// Séparateur ondulé avant une nouvelle partie (valeur : espace réservé au-dessus, en points).
    static let ecritoireSeparator = NSAttributedString.Key("ecritoireSeparator")
    /// Paragraphe du curseur : son filet et son fond sont dessinés avec le texte (impossible qu'ils divergent).
    static let ecritoireFocus = NSAttributedString.Key("ecritoireFocus")
    /// Attribut de rendu temporaire, utilisé seulement pour faire redessiner un paragraphe survolé.
    static let ecritoireHover = NSAttributedString.Key("ecritoireHover")
    /// Verset d'un poème (valeur : son numéro), affiché dans la marge gauche par le fragment.
    static let ecritoireVerse = NSAttributedString.Key("ecritoireVerse")
    /// Ligne `---` d'un poème, dessinée comme un petit ornement centré.
    static let ecritoireOrnament = NSAttributedString.Key("ecritoireOrnament")
}

/// Polices de l'éditeur : Walbaum (texte, grands titres) et Walbaum Grotesk (sous-titres, intro, citations)
/// si elles sont installées ; sinon les polices libres livrées avec l'app (Libre Bodoni, Hanken Grotesk).
struct EditorTheme {
    enum Family { case serif, display, grotesk, groteskBlack }

    let size: CGFloat

    func font(_ family: Family, _ scale: CGFloat = 1, bold: Bool = false, italic: Bool = false) -> NSFont {
        let size = (self.size * scale).rounded()
        let style = bold && italic ? "-BoldItalic" : bold ? "-Bold" : italic ? "-Italic" : ""
        let candidates: [String]
        switch family {
        case .serif: candidates = ["Walbaum10XLPro" + style, "Walbaum10Pro" + style]
        case .display: candidates = ["Walbaum120Pro" + style, "Walbaum10XLPro" + style]
        case .grotesk: candidates = ["WalbaumGroteskBook" + style, "WalbaumGroteskText" + style]
        case .groteskBlack: candidates = [italic ? "WalbaumGroteskBlack-Italic" : "WalbaumGroteskBlack", "WalbaumGroteskBook-Bold"]
        }
        if !FreeFonts.ignoreWalbaum {
            for name in candidates {
                if let font = NSFont(name: name, size: size) { return font }
            }
        }
        // Walbaum absente (police payante, jamais distribuée) : polices libres livrées avec l'app,
        // Libre Bodoni pour le serif, Hanken Grotesk pour le grotesk (licence SIL OFL).
        if let font = FreeFonts.font(family, size: size, bold: bold, italic: italic) { return font }
        // Dernier repli : New York pour le serif, SF pour le grotesk.
        var font = NSFont.systemFont(ofSize: size, weight: bold || family == .groteskBlack ? .bold : .regular)
        if family == .serif || family == .display,
           let d = font.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { font = f }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    static let hidden = NSFont.systemFont(ofSize: 0.01)
}

/// Mise en forme du Markdown façon traitement de texte : titres, corps, intro, citations, images.
/// Les signes Markdown sont masqués, sauf dans le paragraphe où se trouve le curseur, où ils apparaissent estompés.
final class MarkdownHighlighter: NSObject, NSTextStorageDelegate {
    var fontSize: CGFloat = 17 {
        didSet { theme = EditorTheme(size: fontSize) }
    }
    private(set) var theme = EditorTheme(size: 17)
    /// Largeur de la colonne de texte (pour dimensionner les images).
    var columnWidth: CGFloat = 640
    /// Hauteur maximale d'une image (dans l'éditeur ; plus petite à l'export PDF, pour tenir dans la page).
    var maxImageHeight: CGFloat = 900
    /// Résout le nom d'une image `![[nom]]` (relatif au dossier du document).
    var imageProvider: ((String) -> NSImage?)?
    /// Commentaires qui touchent un paragraphe.
    var commentMarks: ((NSRange) -> [(NSRange, CommentMark)])?
    /// Ajouts/suppressions qui touchent un paragraphe (mode « Modifications »).
    var diffMarks: ((NSRange) -> [(NSRange, DiffMark)])?
    /// Avant la remise en forme d'une modification du texte (pour décaler les commentaires).
    var onEdit: ((NSRange, Int) -> Void)?
    /// Mode relecture : tous les marqueurs restent visibles (un « ** » supprimé doit se voir).
    var showAllMarkers = false
    /// Paragraphe (titre en double du document) masqué hors édition.
    var hiddenTitleLocation: Int?
    /// Niveau des titres de partie (le plus haut du document) et position du premier titre :
    /// chaque nouvelle partie, sauf la première, est précédée d'un séparateur ondulé.
    var partLevel = 1
    var firstHeadingLocation: Int?
    /// Position du curseur : les marqueurs de ce paragraphe restent visibles.
    private var activeLocation: Int?
    /// Affichage « poème » : en-tête centré, versets en retrait suspendu, numéros `[n]` dans la marge.
    var poemMode = false
    /// Taille du texte des versets (un peu plus grande que la prose).
    var verseSize: CGFloat { (fontSize * 1.1).rounded() }
    /// Hauteur de ligne des versets (interligne 1,5).
    var verseLineHeight: CGFloat { (verseSize * 1.5).rounded() }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: theme.font(.serif), .foregroundColor: NSColor.bodyText, .paragraphStyle: bodyStyle(exact: true)]
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private let headingRE = regex(#"^(#{1,6})[ \t]+"#)
    private let quoteRE = regex(#"^>[ \t]?"#)
    private let calloutRE = regex(#"^>[ \t]?\[!([A-Za-z-]+)\][^\n]*$"#)
    private let imageRE = regex(#"^!\[\[([^\]\n]+)\]\]\s*$"#)
    private let listRE = regex(#"^([ \t]*)([-*+]|\d+[.)])[ \t]"#)
    private let fenceRE = regex(#"^(?:```|~~~)"#)
    private let ruleRE = regex(#"^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#)
    private let boldRE = regex(#"(?<!\\)(\*\*|__)(?=\S)(.+?)(?<=\S)(?<!\\)\1"#)
    private let italicRE = regex(#"(?<![*_\\\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_\\])\1(?![*_\w])"#)
    private let codeRE = regex(#"`[^`\n]+`"#)
    private let wikiRE = regex(#"(?<!!)\[\[([^\]\n|]+)(?:\|([^\]\n]+))?\]\]"#)
    private let linkRE = regex(#"(?<!!)\[([^\]\n]+)\]\(([^)\n]+)\)"#)
    private let commentRE = regex(#"%%.*?%%|<!--.*?-->"#)
    private let highlightRE = regex(#"(?<!=)==(?=[^\s=])(.+?)(?<=[^\s=])==(?!=)"#)
    private let markRE = regex(#"<mark class="([a-zA-Zéè-]+)">(.+?)</mark>"#)
    private let escapeRE = regex(#"\\([\\`*_{}\[\]()#+\-.!>])"#)

    // MARK: Points d'entrée

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        onEdit?(editedRange, delta)
        let text = textStorage.string as NSString
        var range = text.paragraphRange(for: editedRange)
        // Une ligne de citation dépend de la précédente (encadré intro) : on reprend le bloc entier.
        range = expandToQuoteBlock(range, in: text)
        highlight(textStorage, in: range)
    }

    func highlightAll(_ storage: NSTextStorage) {
        storage.beginEditing()
        highlight(storage, in: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    /// Remet en forme les paragraphes qui touchent ces plages (commentaires ajoutés, sélectionnés…).
    func rehighlight(_ ranges: [NSRange], in storage: NSTextStorage) {
        guard !ranges.isEmpty else { return }
        let text = storage.string as NSString
        storage.beginEditing()
        for r in ranges where r.location <= text.length {
            let clamped = NSRange(location: r.location, length: min(r.length, text.length - r.location))
            highlight(storage, in: text.paragraphRange(for: clamped))
        }
        storage.endEditing()
    }

    /// Commentaires et modifications posés par-dessus la mise en forme Markdown.
    private func decorate(_ storage: NSTextStorage, _ para: NSRange) {
        guard para.length > 0 else { return }
        if let focus = focusLocation, focus >= para.location, focus < NSMaxRange(para) || (focus == NSMaxRange(para) && focus == storage.length),
           para.location != hiddenTitleLocation || poemMode,
           storage.attribute(.ecritoireOrnament, at: para.location, effectiveRange: nil) == nil,
           // Police du dernier caractère visible (le début d'un verset est son numéro masqué).
           let font = storage.attribute(.font, at: max(para.location, NSMaxRange(para) - (NSMaxRange(para) < storage.length || storage.string.hasSuffix("\n") ? 2 : 1)), effectiveRange: nil) as? NSFont,
           font.pointSize >= 4 {
            storage.addAttribute(.ecritoireFocus, value: fontSize, range: para)
        }
        if let commentMarks {
            for (range, mark) in commentMarks(para) {
                let r = NSIntersectionRange(range, para)
                if r.length > 0 { storage.addAttribute(.ecritoireComment, value: mark, range: r) }
                if NSLocationInRange(range.location, para), range.location < storage.length {
                    storage.addAttribute(.ecritoireCommentPin, value: mark, range: NSRange(location: range.location, length: 1))
                }
            }
        }
        if let diffMarks {
            for (range, mark) in diffMarks(para) {
                let r = NSIntersectionRange(range, para)
                guard r.length > 0 else { continue }
                storage.addAttribute(.ecritoireDiff, value: mark, range: r)
                if mark.kind == .deleted {
                    storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                           .strikethroughColor: NSColor.diffDeleted,
                                           .foregroundColor: NSColor.diffDeletedText], range: r)
                }
            }
        }
    }

    /// Le curseur a bougé : on remet en forme l'ancien et le nouveau paragraphe actif.
    @discardableResult
    func setActiveLocation(_ location: Int?, focus: Int? = nil, in storage: NSTextStorage) -> [NSRange] {
        let text = storage.string as NSString
        func paragraph(_ loc: Int?) -> NSRange? {
            guard let loc else { return nil }
            return text.paragraphRange(for: NSRange(location: min(loc, text.length), length: 0))
        }
        let old = paragraph(activeLocation), oldFocus = paragraph(focusLocation)
        activeLocation = location
        focusLocation = focus ?? location
        let new = paragraph(location), newFocus = paragraph(focusLocation)
        guard old != new || oldFocus != newFocus else { return [] }
        storage.beginEditing()
        var done: [NSRange] = []
        for r in [old, new, oldFocus, newFocus].compactMap({ $0 }) where !done.contains(r) && NSMaxRange(r) <= text.length {
            highlight(storage, in: r)
            done.append(r)
        }
        storage.endEditing()
        return done
    }

    /// Vrai si le curseur ou le paragraphe mis en avant change de paragraphe (sinon : rien à remettre en forme).
    func paragraphChanges(active: Int?, focus: Int?, in storage: NSTextStorage) -> Bool {
        let text = storage.string as NSString
        func paragraph(_ loc: Int?) -> NSRange? {
            guard let loc else { return nil }
            return text.paragraphRange(for: NSRange(location: min(loc, text.length), length: 0))
        }
        return paragraph(activeLocation) != paragraph(active) || paragraph(focusLocation) != paragraph(focus ?? active)
    }

    /// Position qui désigne le paragraphe mis en avant (curseur ou début de sélection).
    private(set) var focusLocation: Int?

    private func expandToQuoteBlock(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        while start > 0 {
            let previous = text.paragraphRange(for: NSRange(location: start - 1, length: 0))
            guard text.substring(with: previous).hasPrefix(">") else { break }
            start = previous.location
        }
        return NSRange(location: start, length: NSMaxRange(range) - start)
    }

    // MARK: Paragraphes

    private enum Kind: Equatable {
        case body, empty, heading(Int), quote, intro, calloutHeader, image(String), list, fence, rule
    }

    private func highlight(_ storage: NSTextStorage, in range: NSRange) {
        let text = storage.string as NSString
        guard range.length > 0 || text.length == 0 else { return }
        var location = range.location
        var insideIntro = false
        let poemHeaderEnd = poemMode ? Poem.headerEnd(in: text) : 0
        // État de l'encadré : regarder les lignes de citation qui précèdent le début de la plage.
        if location > 0 { insideIntro = calloutContext(before: location, in: text) }
        repeat {
            let para = text.paragraphRange(for: NSRange(location: location, length: 0))
            let line = text.substring(with: para).trimmingCharacters(in: .newlines)
            if line.hasPrefix(">") {
                if let m = calloutRE.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                    insideIntro = (line as NSString).substring(with: m.range(at: 1)).lowercased() == "intro"
                }
            } else {
                insideIntro = false
            }
            if !(poemMode && highlightPoemParagraph(storage, para, line: line, inHeader: para.location < poemHeaderEnd)) {
                highlightParagraph(storage, para, line: line, inIntro: insideIntro)
            }
            decorate(storage, para)
            location = NSMaxRange(para)
        } while location < NSMaxRange(range) && location < text.length
    }

    /// Vrai si la ligne à `location` fait partie d'un encadré `> [!intro]` commencé plus haut.
    private func calloutContext(before location: Int, in text: NSString) -> Bool {
        var start = location
        while start > 0 {
            let previous = text.paragraphRange(for: NSRange(location: start - 1, length: 0))
            let line = text.substring(with: previous)
            guard line.hasPrefix(">") else { return false }
            if let m = calloutRE.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                return (line as NSString).substring(with: m.range(at: 1)).lowercased() == "intro"
            }
            start = previous.location
        }
        return false
    }

    private func kind(of line: String, inIntro: Bool) -> Kind {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
        if let m = headingRE.firstMatch(in: line, range: full) { return .heading(m.range(at: 1).length) }
        if calloutRE.firstMatch(in: line, range: full) != nil { return .calloutHeader }
        if line.hasPrefix(">") { return inIntro ? .intro : .quote }
        if let m = imageRE.firstMatch(in: line, range: full) { return .image(ns.substring(with: m.range(at: 1))) }
        if fenceRE.firstMatch(in: line, range: full) != nil { return .fence }
        if ruleRE.firstMatch(in: line, range: full) != nil { return .rule }
        if listRE.firstMatch(in: line, range: full) != nil { return .list }
        return .body
    }

    private func bodyStyle(exact: Bool = false) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.3
        if exact {
            style.lineHeightMultiple = 0
            style.minimumLineHeight = (fontSize * 1.4).rounded()
            style.maximumLineHeight = (fontSize * 1.4).rounded()
        }
        // Le paragraphe est l'unité de travail : un vrai blanc entre deux paragraphes.
        style.paragraphSpacing = fontSize * 0.9
        return style
    }

    private func highlightParagraph(_ storage: NSTextStorage, _ para: NSRange, line: String, inIntro: Bool) {
        let active = showAllMarkers || (activeLocation.map { $0 >= para.location && $0 <= para.location + (line as NSString).length } ?? false)
        let kind = kind(of: line, inIntro: inIntro)
        // Titre du document répété en tête du texte : il est affiché au-dessus de la page, jamais dans le texte.
        if para.location == hiddenTitleLocation && !poemMode {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 0.01
            style.maximumLineHeight = 1
            storage.setAttributes([.paragraphStyle: style], range: para)
            hide(storage, para)
            return
        }
        let lineRange = NSRange(location: para.location, length: (line as NSString).length)
        var family: EditorTheme.Family = .serif
        var scale: CGFloat = 1
        var bold = false
        var color = NSColor.bodyText
        let style = bodyStyle()

        switch kind {
        case .heading(let level):
            switch level {
            case 1: family = .display; scale = 2.1; bold = true
                style.paragraphSpacingBefore = fontSize * 2.0; style.paragraphSpacing = fontSize * 0.35
                style.lineHeightMultiple = 1.05
            case 2: family = .grotesk; scale = 1.45; bold = true
                style.paragraphSpacingBefore = fontSize * 1.6; style.paragraphSpacing = fontSize * 0.6
                style.lineHeightMultiple = 1.1
            case 3: family = .groteskBlack; scale = 1.1
                style.paragraphSpacingBefore = fontSize * 1.1; style.paragraphSpacing = fontSize * 0.4
            default: family = .grotesk; scale = 1; bold = true
                style.paragraphSpacingBefore = fontSize * 0.8; style.paragraphSpacing = fontSize * 0.3
            }
        case .intro:
            family = .grotesk; scale = 1.15
            style.lineHeightMultiple = 1.3
            style.paragraphSpacing = fontSize * 0.6
        case .quote:
            // Citation (texte spécial) : Walbaum Grotesk Book gris, justifiée, presque à la taille du corps,
            // interligne un peu plus serré ; pas de fond, juste un petit décalage pour le filet à gauche.
            family = .grotesk; scale = 0.97
            color = .quoteText
            style.firstLineHeadIndent = fontSize * 0.9
            style.headIndent = fontSize * 0.9
            style.tailIndent = 0
            style.alignment = .justified
            style.lineHeightMultiple = 1.2
            style.paragraphSpacingBefore = fontSize * 0.5
            style.paragraphSpacing = fontSize * 1.0
        case .list:
            style.headIndent = fontSize * 1.5
            style.paragraphSpacing = fontSize * 0.25
        case .fence, .rule:
            color = .tertiaryLabelColor
        case .empty, .calloutHeader:
            if !active {
                style.lineHeightMultiple = 0.01
                style.paragraphSpacing = 0
                style.maximumLineHeight = 1
            }
        case .image(let name):
            if let image = imageProvider?(name) {
                let size = displaySize(image)
                style.paragraphSpacingBefore = size.height + fontSize * 0.6
                style.paragraphSpacing = fontSize * 0.9
            }
            color = .tertiaryLabelColor
        case .body:
            break
        }

        // Nouvelle partie : un grand blanc avant le titre, où se dessine le séparateur ondulé.
        var separatorSpace: CGFloat? = nil
        if case .heading(let level) = kind, level == partLevel, let first = firstHeadingLocation, para.location > first {
            separatorSpace = fontSize * 3.6
            style.paragraphSpacingBefore = separatorSpace!
        }
        // Corps et listes : interligne exact de 1,4 × la taille (comme une ligne CSS), plus régulier
        // que le multiplicateur de la police.
        if kind == .body || kind == .list {
            style.lineHeightMultiple = 0
            style.minimumLineHeight = (fontSize * 1.4).rounded()
            style.maximumLineHeight = (fontSize * 1.4).rounded()
        }
        let font = theme.font(family, scale, bold: bold)
        storage.setAttributes([.font: font, .foregroundColor: color, .paragraphStyle: style], range: para)
        if let separatorSpace { storage.addAttribute(.ecritoireSeparator, value: separatorSpace, range: para) }
        switch kind {
        case .quote: storage.addAttribute(.ecritoireBlock, value: "citation", range: para)
        case .intro: storage.addAttribute(.ecritoireBlock, value: "intro", range: para)
        default: break
        }

        // Paragraphes à masquer entièrement hors édition.
        switch kind {
        case .empty, .calloutHeader:
            if !active { hide(storage, para) } else { dim(storage, lineRange) }
            return
        case .image(let name):
            if imageProvider?(name) != nil {
                if active {
                    storage.addAttribute(.font, value: theme.font(.grotesk, 0.75), range: lineRange)
                } else {
                    hide(storage, para)
                }
                // L'image doit rester attachée même si le texte est masqué.
                if let image = imageProvider?(name) { storage.addAttribute(.ecritoireImage, value: image, range: para) }
            }
            return
        case .fence, .rule:
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: fontSize * 0.8, weight: .regular), range: lineRange)
            return
        default: break
        }

        // Marqueurs de début de ligne.
        let full = NSRange(location: 0, length: (line as NSString).length)
        var marker: NSRange?
        if case .heading = kind, let m = headingRE.firstMatch(in: line, range: full) { marker = m.range }
        if kind == .quote || kind == .intro, let m = quoteRE.firstMatch(in: line, range: full) { marker = m.range }
        if let marker {
            let r = NSRange(location: para.location + marker.location, length: marker.length)
            active ? dim(storage, r) : hide(storage, r)
        }
        if kind == .list, let m = listRE.firstMatch(in: line, range: full) {
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor,
                                 range: NSRange(location: para.location + m.range(at: 2).location, length: m.range(at: 2).length))
        }

        inline(storage, line: line, offset: para.location, family: family, scale: scale, bold: bold, active: active)
    }

    // MARK: Mise en forme en ligne

    private func inline(_ storage: NSTextStorage, line: String, offset: Int, family: EditorTheme.Family,
                        scale: CGFloat, bold: Bool, active: Bool) {
        let full = NSRange(location: 0, length: (line as NSString).length)
        func r(_ range: NSRange) -> NSRange { NSRange(location: offset + range.location, length: range.length) }
        func marker(_ range: NSRange) { active ? dim(storage, r(range)) : hide(storage, r(range)) }

        boldRE.enumerateMatches(in: line, range: full) { m, _, _ in
            guard let m else { return }
            let italicInside = storage.attribute(.font, at: r(m.range(at: 2)).location, effectiveRange: nil)
                .flatMap { $0 as? NSFont }.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false
            storage.addAttribute(.font, value: theme.font(family, scale, bold: true, italic: italicInside), range: r(m.range(at: 2)))
            let len = m.range(at: 1).length
            marker(NSRange(location: m.range.location, length: len))
            marker(NSRange(location: NSMaxRange(m.range) - len, length: len))
        }
        italicRE.enumerateMatches(in: line, range: full) { m, _, _ in
            guard let m else { return }
            // Respecte le gras déjà posé à l'intérieur.
            let inner = r(m.range(at: 2))
            storage.enumerateAttribute(.font, in: inner) { value, sub, _ in
                let isBold = (value as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? bold
                storage.addAttribute(.font, value: self.theme.font(family, scale, bold: isBold, italic: true), range: sub)
            }
            marker(NSRange(location: m.range.location, length: 1))
            marker(NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }
        codeRE.enumerateMatches(in: line, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: fontSize * scale * 0.85, weight: .regular),
                                   .foregroundColor: NSColor.secondaryLabelColor], range: r(m.range))
        }
        wikiRE.enumerateMatches(in: line, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: r(m.range))
            marker(NSRange(location: m.range.location, length: 2))
            marker(NSRange(location: NSMaxRange(m.range) - 2, length: 2))
            if m.range(at: 2).location != NSNotFound {
                // [[cible|libellé]] : seule l'étiquette reste visible.
                marker(NSRange(location: m.range(at: 1).location, length: m.range(at: 2).location - m.range(at: 1).location))
            }
        }
        linkRE.enumerateMatches(in: line, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: r(m.range(at: 1)))
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r(m.range(at: 1)))
            marker(NSRange(location: m.range.location, length: 1))
            let tailStart = NSMaxRange(m.range(at: 1))
            marker(NSRange(location: tailStart, length: NSMaxRange(m.range) - tailStart))
        }
        commentRE.enumerateMatches(in: line, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r(m.range))
        }
        highlightRE.enumerateMatches(in: line, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.ecritoireHighlight, value: HighlightColor.jaune.rawValue, range: r(m.range(at: 1)))
            marker(NSRange(location: m.range.location, length: 2))
            marker(NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        markRE.enumerateMatches(in: line, range: full) { m, _, _ in
            guard let m else { return }
            let color = (line as NSString).substring(with: m.range(at: 1))
            storage.addAttribute(.ecritoireHighlight, value: color, range: r(m.range(at: 2)))
            marker(NSRange(location: m.range.location, length: m.range(at: 2).location - m.range.location))
            let closeStart = NSMaxRange(m.range(at: 2))
            marker(NSRange(location: closeStart, length: NSMaxRange(m.range) - closeStart))
        }
        escapeRE.enumerateMatches(in: line, range: full) { m, _, _ in
            guard let m else { return }
            marker(NSRange(location: m.range.location, length: 1))
        }
    }

    // MARK: Poème

    /// Mise en forme d'un paragraphe en affichage poème. Faux si le paragraphe garde la mise en forme ordinaire
    /// (titre, citation, image… au milieu des versets).
    private func highlightPoemParagraph(_ storage: NSTextStorage, _ para: NSRange, line: String, inHeader: Bool) -> Bool {
        let active = showAllMarkers || (activeLocation.map { $0 >= para.location && $0 <= para.location + (line as NSString).length } ?? false)
        let lineRange = NSRange(location: para.location, length: (line as NSString).length)
        let full = NSRange(location: 0, length: lineRange.length)
        let kind = kind(of: line, inIntro: false)
        let style = NSMutableParagraphStyle()
        // Lignes vides : jamais affichées (l'espace entre versets vient du style des versets).
        if kind == .empty {
            style.lineHeightMultiple = 0.01
            style.maximumLineHeight = 1
            storage.setAttributes([.paragraphStyle: style], range: para)
            hide(storage, para)
            return true
        }
        if inHeader {
            // En-tête : bloc de titre centré au-dessus du poème.
            style.alignment = .center
            if kind == .rule {
                // `---` : petit ornement centré dessiné par le fragment.
                style.minimumLineHeight = (fontSize * 2.6).rounded()
                style.maximumLineHeight = (fontSize * 2.6).rounded()
                storage.setAttributes([.paragraphStyle: style, .ecritoireOrnament: fontSize], range: para)
                active ? storage.addAttributes([.font: theme.font(.grotesk, 0.7), .foregroundColor: NSColor.tertiaryLabelColor], range: lineRange)
                       : hide(storage, para)
                return true
            }
            if case .heading = kind, let m = headingRE.firstMatch(in: line, range: full) {
                style.lineHeightMultiple = 1.05
                style.paragraphSpacingBefore = fontSize * 1.2
                style.paragraphSpacing = fontSize * 0.9
                storage.setAttributes([.font: theme.font(.display, 2.0), .foregroundColor: NSColor.bodyText, .paragraphStyle: style], range: para)
                let marker = NSRange(location: para.location + m.range.location, length: m.range.length)
                active ? dim(storage, marker) : hide(storage, marker)
                inline(storage, line: line, offset: para.location, family: .display, scale: 2.0, bold: false, active: active)
                return true
            }
            // Ligne de révision, note : petites capitales grises, colonne resserrée.
            let inset = (columnWidth * 0.1).rounded()
            style.firstLineHeadIndent = inset
            style.headIndent = inset
            style.tailIndent = -inset
            style.lineHeightMultiple = 1.3
            style.paragraphSpacing = fontSize * 0.55
            let font = smallCaps(theme.font(.grotesk, 0.74))
            storage.setAttributes([.font: font, .foregroundColor: Palette.secondaryText, .kern: 0.4, .paragraphStyle: style], range: para)
            inline(storage, line: line, offset: para.location, family: .grotesk, scale: 0.74, bold: false, active: active)
            return true
        }
        guard kind == .body || kind == .list else { return false }
        // Verset : fer à gauche, retrait suspendu (lignes suivantes rentrées de 1,5 em), une ligne de blanc après.
        let size = verseSize
        style.minimumLineHeight = verseLineHeight
        style.maximumLineHeight = verseLineHeight
        style.firstLineHeadIndent = 0
        style.headIndent = (size * 1.5).rounded()
        style.paragraphSpacing = verseLineHeight
        style.alignment = .left
        storage.setAttributes([.font: theme.font(.serif, 1.1), .foregroundColor: NSColor.bodyText, .paragraphStyle: style], range: para)
        if let marker = Poem.marker(in: line) {
            // Le numéro n'est pas du texte : masqué, même pendant l'édition ; il est dessiné dans la marge.
            hide(storage, NSRange(location: para.location + marker.range.location, length: marker.range.length))
            storage.addAttribute(.ecritoireVerse, value: marker.number, range: para)
        }
        inline(storage, line: line, offset: para.location, family: .serif, scale: 1.1, bold: false, active: active)
        return true
    }

    /// Variante en petites capitales (repli : la police telle quelle).
    private func smallCaps(_ font: NSFont) -> NSFont {
        let settings: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector],
        ]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: settings])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private func hide(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttributes([.font: EditorTheme.hidden, .foregroundColor: NSColor.clear], range: range)
    }

    private func dim(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
    }

    func displaySize(_ image: NSImage) -> NSSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return .zero }
        let width = min(columnWidth, size.width)
        var height = width * size.height / size.width
        let maxHeight = maxImageHeight
        if height > maxHeight { height = maxHeight }
        return NSSize(width: (height * size.width / size.height).rounded(), height: height.rounded())
    }
}

// MARK: - Fragments de mise en page (TextKit 2)

/// Couleurs de surligneur. Le jaune s'écrit `==texte==` ; les autres `<mark class="vert">texte</mark>`.
enum HighlightColor: String, CaseIterable, Identifiable {
    case jaune, vert, rose, bleu

    var id: String { rawValue }

    var nsColor: NSColor {
        switch self {
        case .jaune: return NSColor(srgbRed: 1.00, green: 0.86, blue: 0.30, alpha: 1)
        case .vert: return NSColor(srgbRed: 0.55, green: 0.86, blue: 0.55, alpha: 1)
        case .rose: return NSColor(srgbRed: 1.00, green: 0.60, blue: 0.70, alpha: 1)
        case .bleu: return NSColor(srgbRed: 0.55, green: 0.78, blue: 1.00, alpha: 1)
        }
    }

    /// Opacité du « coup de feutre » (plus faible en mode sombre).
    static func alpha(dark: Bool) -> CGFloat { dark ? 0.38 : 0.55 }
}

/// Fragment de paragraphe qui dessine les surlignages comme un coup de feutre (bords arrondis, légèrement inclinés).
class RichLayoutFragment: NSTextLayoutFragment {
    override var renderingSurfaceBounds: CGRect {
        // Assez large pour la pastille de commentaire dans la marge droite et le séparateur au-dessus.
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        let margin = CGRect(x: width - layoutFragmentFrame.minX, y: 0, width: 56, height: layoutFragmentFrame.height)
        // À gauche : filet du paragraphe actif et numéro de verset dans la marge.
        let full = CGRect(x: -layoutFragmentFrame.minX - 76, y: -6, width: width + 116, height: layoutFragmentFrame.height + 12)
        return super.renderingSurfaceBounds.insetBy(dx: -6, dy: -4).union(margin).union(full)
    }

    /// Rectangle d'une suite de caractères sur une ligne, en coordonnées de dessin.
    private func runRect(_ line: NSTextLineFragment, _ run: NSRange, _ string: NSAttributedString, at point: CGPoint) -> CGRect? {
        let x0 = line.locationForCharacter(at: run.location).x
        let x1 = line.locationForCharacter(at: NSMaxRange(run)).x
        guard x1 > x0 else { return nil }
        let font = string.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont
        let ascender = max(font?.ascender ?? 14, 8)
        let descender = font?.descender ?? -4
        let baseline = line.typographicBounds.minY + line.glyphOrigin.y
        return CGRect(x: line.typographicBounds.minX + x0, y: baseline - ascender * 0.92,
                      width: x1 - x0, height: ascender * 0.92 - descender + 1).offsetBy(dx: point.x, dy: point.y)
    }

    /// Bord droit de la colonne de texte, en coordonnées de dessin.
    private func containerRight(at point: CGPoint) -> CGFloat {
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        return point.x - layoutFragmentFrame.minX + width
    }

    func drawAnnotations(at point: CGPoint, in context: CGContext) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for line in textLineFragments {
            let string = line.attributedString
            let range = line.characterRange
            guard range.length > 0, NSMaxRange(range) <= string.length else { continue }
            // Modifications : fond vert pour l'ajouté, rose pour le supprimé ; encadré pour la modification courante.
            string.enumerateAttribute(.ecritoireDiff, in: range) { value, run, _ in
                guard let mark = value as? DiffMark, let rect = runRect(line, run, string, at: point) else { return }
                let color = mark.kind == .inserted ? NSColor.diffInserted : NSColor.diffDeleted
                context.saveGState()
                context.setFillColor(color.withAlphaComponent(mark.current ? (dark ? 0.38 : 0.30) : (dark ? 0.22 : 0.16)).cgColor)
                context.addPath(CGPath(roundedRect: rect.insetBy(dx: -1.5, dy: 0), cornerWidth: 3, cornerHeight: 3, transform: nil))
                context.fillPath()
                if mark.kind == .inserted {
                    context.setFillColor(color.cgColor)
                    context.fill(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1.5))
                }
                context.restoreGState()
            }
            // Commentaires : soulignement lavande, teinte si sélectionné.
            string.enumerateAttribute(.ecritoireComment, in: range) { value, run, _ in
                guard let mark = value as? CommentMark, let rect = runRect(line, run, string, at: point) else { return }
                context.saveGState()
                if mark.selected {
                    context.setFillColor(Palette.accent.withAlphaComponent(dark ? 0.28 : 0.18).cgColor)
                    context.fill(rect.insetBy(dx: -1, dy: 0))
                }
                context.setFillColor(Palette.accent.withAlphaComponent(mark.resolved ? 0.35 : 0.9).cgColor)
                context.fill(CGRect(x: rect.minX, y: rect.maxY, width: rect.width, height: mark.selected ? 2 : 1.5))
                context.restoreGState()
            }
            // Pastille numérotée dans la marge droite, à la hauteur du début du passage.
            string.enumerateAttribute(.ecritoireCommentPin, in: range) { value, run, _ in
                guard let mark = value as? CommentMark else { return }
                let baseline = line.typographicBounds.minY + line.glyphOrigin.y + point.y
                let size: CGFloat = 20
                let pin = CGRect(x: containerRight(at: point) + 18, y: baseline - size + 4, width: size, height: size)
                CommentPin.draw(number: mark.number, in: pin, context: context, selected: mark.selected, resolved: mark.resolved)
            }
        }
    }

    func drawHighlights(at point: CGPoint, in context: CGContext) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for line in textLineFragments {
            let string = line.attributedString
            let range = line.characterRange
            guard range.length > 0, NSMaxRange(range) <= string.length else { continue }
            string.enumerateAttribute(.ecritoireHighlight, in: range) { value, run, _ in
                guard let name = value as? String else { return }
                let color = (HighlightColor(rawValue: name) ?? .jaune).nsColor
                let x0 = line.locationForCharacter(at: run.location).x
                let x1 = line.locationForCharacter(at: NSMaxRange(run)).x
                guard x1 > x0 else { return }
                let font = string.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont
                let ascender = font?.ascender ?? 14
                let descender = font?.descender ?? -4
                let baseline = line.typographicBounds.minY + line.glyphOrigin.y
                let rect = CGRect(x: line.typographicBounds.minX + x0 - 2, y: baseline - ascender * 0.92,
                                  width: x1 - x0 + 4, height: ascender * 0.92 - descender + 1)
                    .offsetBy(dx: point.x, dy: point.y)
                // Coup de feutre : parallélogramme aux coins arrondis, un peu plus épais au départ.
                let slant: CGFloat = 2.5
                let path = CGMutablePath()
                path.move(to: CGPoint(x: rect.minX + slant, y: rect.minY + 1))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addQuadCurve(to: CGPoint(x: rect.maxX - slant, y: rect.maxY), control: CGPoint(x: rect.maxX + 3, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 1))
                path.addQuadCurve(to: CGPoint(x: rect.minX + slant, y: rect.minY + 1), control: CGPoint(x: rect.minX - 3, y: rect.midY))
                path.closeSubpath()
                context.saveGState()
                context.setFillColor(color.withAlphaComponent(HighlightColor.alpha(dark: dark)).cgColor)
                context.addPath(path)
                context.fillPath()
                context.restoreGState()
            }
        }
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        drawFocus(at: point, in: context)
        drawSeparator(at: point, in: context)
        drawVerseNumber(at: point, in: context)
        drawOrnament(at: point, in: context)
        drawHighlights(at: point, in: context)
        drawAnnotations(at: point, in: context)
        super.draw(at: point, in: context)
    }

    /// Paragraphe du curseur : léger fond lavande et filet dans la marge gauche, à la hauteur exacte des lignes dessinées.
    private func drawFocus(at point: CGPoint, in context: CGContext) {
        // Dernière ligne réelle : en fin de document, TextKit ajoute une ligne vide après le dernier retour à la ligne.
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
              let first = textLineFragments.first,
              let last = textLineFragments.last(where: { $0.characterRange.length > 0 }) ?? textLineFragments.last else { return }
        // Paragraphe du curseur (marqué dans le texte) ou paragraphe survolé (repère de survol, sans remise en page).
        let focusSize = paragraph.attributedString.attribute(.ecritoireFocus, at: 0, effectiveRange: nil) as? CGFloat
        let hovered = focusSize == nil && HoverParagraph.matches(rangeInElement)
        guard let size = focusSize ?? (hovered ? HoverParagraph.fontSize : nil) else { return }
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        let left = point.x - layoutFragmentFrame.minX
        let top = point.y + first.typographicBounds.minY
        let bottom = point.y + last.typographicBounds.maxY
        guard bottom - top > 6 else { return }
        let gutter = size * 1.1
        context.saveGState()
        context.setFillColor(Palette.accent.withAlphaComponent(hovered ? 0.03 : 0.045).cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: left - gutter * 0.6, y: top - 4, width: width + gutter * 1.2, height: bottom - top + 8),
                               cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.fillPath()
        context.setFillColor(Palette.accent.withAlphaComponent(hovered ? 0.3 : 0.7).cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: left - gutter, y: top + 3, width: 3, height: bottom - top - 6),
                               cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    /// Numéro du verset dans la marge gauche : petit, Walbaum Grotesk, chiffres tabulaires, aligné à droite sur
    /// la ligne de base de la première ligne ; lavande pâle, plus marqué sur le verset actif ou survolé.
    private func drawVerseNumber(at point: CGPoint, in context: CGContext) {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
              let number = paragraph.attributedString.attribute(.ecritoireVerse, at: 0, effectiveRange: nil) as? Int,
              let first = textLineFragments.first else { return }
        let string = paragraph.attributedString
        let focusSize = string.attribute(.ecritoireFocus, at: 0, effectiveRange: nil) as? CGFloat
        let hovered = HoverParagraph.matches(rangeInElement)
        let size = focusSize ?? HoverParagraph.fontSize
        let base = EditorTheme(size: size).font(.grotesk, 0.7)
        let font = NSFont(descriptor: base.fontDescriptor.addingAttributes([.featureSettings: [
            [NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector],
        ]]), size: base.pointSize) ?? base
        let color: NSColor = focusSize != nil ? Palette.accent : hovered ? Palette.accent.withAlphaComponent(0.75) : NSColor.verseNumber
        let label = NSAttributedString(string: "\(number)", attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(label)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        // Ligne de base de la première ligne du verset, en coordonnées de dessin.
        let baseline = point.y + first.typographicBounds.minY + first.glyphOrigin.y
        let right = point.x - layoutFragmentFrame.minX - (size * 1.1 + 12).rounded()
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: right - CGFloat(width), y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Ligne `---` d'un poème : petite vague lavande centrée.
    private func drawOrnament(at point: CGPoint, in context: CGContext) {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
              let size = paragraph.attributedString.attribute(.ecritoireOrnament, at: 0, effectiveRange: nil) as? CGFloat,
              let first = textLineFragments.first else { return }
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        let midX = point.x - layoutFragmentFrame.minX + width / 2
        let y = point.y + first.typographicBounds.midY
        let scale = size / 19
        let wavelength = 12 * scale, amplitude = 2.2 * scale
        let halves = 6
        let total = wavelength / 2 * CGFloat(halves)
        let path = CGMutablePath()
        var x = midX - total / 2
        path.move(to: CGPoint(x: x, y: y))
        for i in 0..<halves {
            let step = wavelength / 2, peak = i % 2 == 0 ? -amplitude : amplitude
            path.addCurve(to: CGPoint(x: x + step, y: y),
                          control1: CGPoint(x: x + step * 0.3642, y: y + peak * 1.3),
                          control2: CGPoint(x: x + step * 0.6358, y: y + peak * 1.3))
            x += step
        }
        context.saveGState()
        context.setStrokeColor(NSColor.separatorWave.cgColor)
        context.setLineWidth(1.3 * max(1, scale * 0.9))
        context.setLineCap(.round)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// Vague en pointillés sur toute la largeur de la colonne, au milieu du blanc qui précède une partie :
    /// une seule sinusoïde régulière (chemin de Bézier), pointillés réguliers le long de la courbe.
    private func drawSeparator(at point: CGPoint, in context: CGContext) {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
              let space = paragraph.attributedString.attribute(.ecritoireSeparator, at: 0, effectiveRange: nil) as? CGFloat,
              let first = textLineFragments.first else { return }
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        let left = point.x - layoutFragmentFrame.minX
        let y = point.y + first.typographicBounds.minY - space * 0.55
        let scale = max(0.6, space / (17 * 3.6)) // suit le zoom
        // Trait plein, ondulation douce et régulière (comme le séparateur « Nouveau » de Claude).
        let wavelength: CGFloat = 15 * scale, amplitude: CGFloat = 2 * scale
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: y))
        let half = wavelength / 2
        let count = max(1, Int((width / half).rounded(.down)))
        let step = width / CGFloat(count)
        var x: CGFloat = 0
        var up = true
        for _ in 0..<count {
            let peak = up ? -amplitude : amplitude
            // Demi-onde : courbe cubique proche d'une sinusoïde (tangentes continues entre deux demi-ondes).
            path.addCurve(to: CGPoint(x: left + x + step, y: y),
                          control1: CGPoint(x: left + x + step * 0.3642, y: y + peak * 1.3),
                          control2: CGPoint(x: left + x + step * 0.6358, y: y + peak * 1.3))
            x += step
            up.toggle()
        }
        context.saveGState()
        context.setShouldAntialias(true)
        context.setStrokeColor(NSColor.separatorWave.cgColor)
        context.setLineWidth(1.25 * max(1, scale * 0.9))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}

/// Dessine l'image d'un paragraphe `![[…]]` dans l'espace réservé au-dessus de la ligne.
final class ImageLayoutFragment: RichLayoutFragment {
    var image: NSImage?
    var imageSize: NSSize = .zero

    private var imageRect: CGRect {
        let top = (textLineFragments.first?.typographicBounds.minY ?? layoutFragmentFrame.height)
        let spacing = imageSize.height
        return CGRect(x: 0, y: max(0, top - spacing - 10), width: imageSize.width, height: imageSize.height)
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(imageRect)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let image {
            let rect = imageRect.offsetBy(dx: point.x, dy: point.y)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        }
        super.draw(at: point, in: context)
    }
}

/// Fond gris clair et filet à gauche derrière les paragraphes de citation.
final class QuoteLayoutFragment: RichLayoutFragment {
    var inset: CGFloat = 12
    /// Retrait gauche et droit du texte de citation (le fond déborde de `inset` de chaque côté).
    var indent: CGFloat = 24

    /// Filet vertical à gauche de la citation, à hauteur des lignes de texte (pas de fond).
    private var barRect: CGRect {
        let lines = textLineFragments
        let top = (lines.first?.typographicBounds.minY ?? 0) + 2
        let bottom = (lines.last?.typographicBounds.maxY ?? layoutFragmentFrame.height) - 2
        let left = lines.map(\.typographicBounds.minX).min() ?? 0
        return CGRect(x: left - inset, y: top, width: 2.5, height: max(0, bottom - top))
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(barRect)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setFillColor(NSColor.quaternaryLabelColor.cgColor)
        context.addPath(CGPath(roundedRect: barRect.offsetBy(dx: point.x, dy: point.y), cornerWidth: 1.25, cornerHeight: 1.25, transform: nil))
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context) // surlignages puis texte
    }
}

/// Paragraphe survolé par la souris : son cadre est dessiné en plus léger par le fragment.
enum HoverParagraph {
    nonisolated(unsafe) static var range: NSTextRange?
    nonisolated(unsafe) static var fontSize: CGFloat = 19
    static func matches(_ other: NSTextRange) -> Bool {
        guard let range else { return false }
        return range.location.compare(other.location) == .orderedSame
    }
}

/// Pastille de commentaire : rond lavande avec son numéro (« + » pour un brouillon).
enum CommentPin {
    static func draw(number: Int, in rect: CGRect, context: CGContext, selected: Bool, resolved: Bool) {
        context.saveGState()
        let fill = resolved ? Palette.secondaryText : Palette.accent
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: selected ? 6 : 3,
                          color: NSColor.black.withAlphaComponent(0.18).cgColor)
        context.setFillColor(fill.cgColor)
        let r = selected ? rect.insetBy(dx: -2, dy: -2) : rect
        context.fillEllipse(in: r)
        context.restoreGState()
        let label = number == 0 ? "+" : "\(number)"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: number > 9 ? 10 : 11.5, weight: .bold),
                                                    .foregroundColor: NSColor.white]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        str.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension NSColor {
    /// Texte courant : gris très foncé (#333), moins dur que le noir pur.
    static let bodyText = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.86, green: 0.85, blue: 0.82, alpha: 1) : NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
    }
    /// Texte des citations : gris moyen.
    static let quoteText = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.66, alpha: 1) : NSColor(srgbRed: 0.43, green: 0.43, blue: 0.43, alpha: 1)
    }
    /// Séparateur ondulé entre deux parties : lavande clair.
    static let separatorWave = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.45, green: 0.38, blue: 0.62, alpha: 1) : NSColor(srgbRed: 0.79, green: 0.72, blue: 0.91, alpha: 1)
    }
    /// Numéros de versets : lavande pâle.
    static let verseNumber = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.48, blue: 0.72, alpha: 1) : NSColor(srgbRed: 0.70, green: 0.62, blue: 0.86, alpha: 1)
    }
    static let diffInserted = NSColor(srgbRed: 0.20, green: 0.66, blue: 0.36, alpha: 1)
    static let diffDeleted = NSColor(srgbRed: 0.86, green: 0.24, blue: 0.24, alpha: 1)
    static let diffDeletedText = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.95, green: 0.55, blue: 0.55, alpha: 1) : NSColor(srgbRed: 0.70, green: 0.18, blue: 0.18, alpha: 1)
    }
    static let quoteBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.05) : NSColor(red: 0.955, green: 0.958, blue: 0.965, alpha: 1)
    }
    /// Fond autour de la page, comme le « bureau » de Scrivener.
    static let deskBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.11, alpha: 1) : NSColor(red: 0.936, green: 0.930, blue: 0.960, alpha: 1)
    }
}

/// Choisit le fragment de mise en page selon le paragraphe (image, citation, ordinaire).
final class FragmentProvider: NSObject, NSTextLayoutManagerDelegate {
    weak var highlighter: MarkdownHighlighter?

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            let attrs = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
            if let image = attrs[.ecritoireImage] as? NSImage {
                let fragment = ImageLayoutFragment(textElement: textElement, range: textElement.elementRange)
                fragment.image = image
                fragment.imageSize = highlighter?.displaySize(image) ?? image.size
                return fragment
            }
            if (attrs[.ecritoireBlock] as? String) == "citation" {
                let fragment = QuoteLayoutFragment(textElement: textElement, range: textElement.elementRange)
                fragment.indent = (highlighter?.fontSize ?? 17) * 0.9
                fragment.inset = (highlighter?.fontSize ?? 17) * 0.7
                return fragment
            }
        }
        // Toujours un RichLayoutFragment : un fragment peut être réutilisé après l'ajout d'un surlignage.
        return RichLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}
