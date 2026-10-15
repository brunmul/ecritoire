import AppKit

/// Style de paragraphe proposé par la barre d'édition, et sa traduction en Markdown.
enum BlockStyle: String, CaseIterable, Identifiable {
    case corps, titre1, titre2, titre3, intro, citation, liste

    var id: String { rawValue }

    var label: String {
        switch self {
        case .corps: return "Corps de texte"
        case .titre1: return "Titre 1"
        case .titre2: return "Titre 2"
        case .titre3: return "Titre 3"
        case .intro: return "Intro"
        case .citation: return "Citation"
        case .liste: return "Liste"
        }
    }

    var prefix: String {
        switch self {
        case .corps: return ""
        case .titre1: return "# "
        case .titre2: return "## "
        case .titre3: return "### "
        case .intro, .citation: return "> "
        case .liste: return "- "
        }
    }

    /// Style du paragraphe qui contient `location`.
    static func at(_ location: Int, in text: NSString) -> BlockStyle {
        guard text.length > 0 else { return .corps }
        let para = text.paragraphRange(for: NSRange(location: min(location, text.length), length: 0))
        let line = text.substring(with: para).trimmingCharacters(in: .newlines)
        if line.hasPrefix("### ") || line.hasPrefix("#### ") { return .titre3 }
        if line.hasPrefix("## ") { return .titre2 }
        if line.hasPrefix("# ") { return .titre1 }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil { return .liste }
        if line.hasPrefix(">") {
            if line.lowercased().hasPrefix("> [!intro]") { return .intro }
            // Remonter jusqu'à l'en-tête éventuel de l'encadré.
            var start = para.location
            while start > 0 {
                let previous = text.paragraphRange(for: NSRange(location: start - 1, length: 0))
                let prevLine = text.substring(with: previous)
                guard prevLine.hasPrefix(">") else { break }
                if prevLine.lowercased().hasPrefix("> [!intro]") { return .intro }
                if prevLine.hasPrefix("> [!") { break }
                start = previous.location
            }
            return .citation
        }
        return .corps
    }
}

enum EditorCommand {
    case bold, italic, wikiLink, comment
    case highlight(HighlightColor)
    case eraseHighlight
    case block(BlockStyle)
}

@MainActor
protocol EditorCommandTarget: AnyObject {
    func perform(_ command: EditorCommand)
}

// MARK: - Mise en œuvre dans la vue texte (une seule étape d'annulation par commande)

extension WritingTextView: EditorCommandTarget {
    private var text: NSString { string as NSString }

    func perform(_ command: EditorCommand) {
        // Chaque commande est une étape d'annulation distincte.
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        switch command {
        case .bold: toggleWrap(open: "**", close: "**")
        case .italic: toggleWrap(open: "*", close: "*")
        case .wikiLink: toggleWrap(open: "[[", close: "]]")
        case .highlight(let color): applyHighlight(color)
        case .eraseHighlight: eraseHighlights()
        case .block(let style): setBlock(style)
        case .comment: onComment?(selectedRange())
        }
    }

    // MARK: Outils

    private func replace(_ range: NSRange, with replacement: String, select: NSRange?) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        if let select { setSelectedRange(select) }
    }

    /// Sélection sans espaces de bord ; à défaut, le mot sous le curseur.
    private func targetRange() -> NSRange {
        var range = selectedRange()
        if range.length == 0 {
            range = selectionRange(forProposedRange: range, granularity: .selectByWord)
        }
        let t = text
        while range.length > 0, let c = UnicodeScalar(t.character(at: range.location)),
              CharacterSet.whitespacesAndNewlines.contains(c) { range.location += 1; range.length -= 1 }
        while range.length > 0, let c = UnicodeScalar(t.character(at: NSMaxRange(range) - 1)),
              CharacterSet.whitespacesAndNewlines.contains(c) { range.length -= 1 }
        return range
    }

    private func count(_ char: unichar, before location: Int) -> Int {
        var n = 0
        var i = location - 1
        while i >= 0 && text.character(at: i) == char { n += 1; i -= 1 }
        return n
    }

    private func count(_ char: unichar, after location: Int) -> Int {
        var n = 0
        var i = location
        while i < text.length && text.character(at: i) == char { n += 1; i += 1 }
        return n
    }

    // MARK: Gras, italique, lien

    private func toggleWrap(open: String, close: String) {
        let range = targetRange()
        guard range.length > 0 else { return }
        let inner = text.substring(with: range)
        let o = (open as NSString).length, c = (close as NSString).length

        // Déjà entouré ? (Pour * et **, on compte les astérisques autour : *** = gras + italique.)
        var wrapped = false
        if open.allSatisfy({ $0 == "*" }) {
            let star = unichar(UInt8(ascii: "*"))
            let around = min(count(star, before: range.location), count(star, after: NSMaxRange(range)))
            wrapped = o == 2 ? around >= 2 : around % 2 == 1
        } else if range.location >= o, NSMaxRange(range) + c <= text.length {
            wrapped = text.substring(with: NSRange(location: range.location - o, length: o)) == open
                && text.substring(with: NSRange(location: NSMaxRange(range), length: c)) == close
        }
        if wrapped {
            replace(NSRange(location: range.location - o, length: range.length + o + c), with: inner,
                    select: NSRange(location: range.location - o, length: range.length))
        } else if inner.hasPrefix(open) && inner.hasSuffix(close) && range.length > o + c {
            let stripped = (inner as NSString).substring(with: NSRange(location: o, length: range.length - o - c))
            replace(range, with: stripped, select: NSRange(location: range.location, length: (stripped as NSString).length))
        } else {
            replace(range, with: open + inner + close, select: NSRange(location: range.location + o, length: range.length))
        }
    }

    // MARK: Surligneur

    private static let highlightPattern = try! NSRegularExpression(
        pattern: #"(?<!=)==(?=[^\s=])(.+?)(?<=[^\s=])==(?!=)|<mark class="([a-zA-Zéè-]+)">(.+?)</mark>"#)

    private struct ExistingHighlight {
        let whole: NSRange
        let inner: NSRange
        let color: HighlightColor
    }

    private func highlights(touching range: NSRange) -> [ExistingHighlight] {
        let para = text.paragraphRange(for: range)
        var found: [ExistingHighlight] = []
        Self.highlightPattern.enumerateMatches(in: string, range: para) { m, _, _ in
            guard let m, NSIntersectionRange(m.range, range).length > 0 || NSLocationInRange(range.location, m.range) else { return }
            if m.range(at: 1).location != NSNotFound {
                found.append(ExistingHighlight(whole: m.range, inner: m.range(at: 1), color: .jaune))
            } else {
                let name = text.substring(with: m.range(at: 2))
                found.append(ExistingHighlight(whole: m.range, inner: m.range(at: 3), color: HighlightColor(rawValue: name) ?? .jaune))
            }
        }
        return found
    }

    private func wrapper(_ color: HighlightColor) -> (String, String) {
        color == .jaune ? ("==", "==") : ("<mark class=\"\(color.rawValue)\">", "</mark>")
    }

    private func applyHighlight(_ color: HighlightColor) {
        let range = targetRange()
        guard range.length > 0 else { return }
        if let existing = highlights(touching: range).first, NSLocationInRange(range.location, existing.whole) || existing.inner == range {
            let inner = text.substring(with: existing.inner)
            if existing.color == color {
                // Même couleur : on retire le surlignage.
                replace(existing.whole, with: inner, select: NSRange(location: existing.whole.location, length: (inner as NSString).length))
            } else {
                let (o, c) = wrapper(color)
                replace(existing.whole, with: o + inner + c,
                        select: NSRange(location: existing.whole.location + (o as NSString).length, length: (inner as NSString).length))
                sweep(over: NSRange(location: existing.whole.location + (o as NSString).length, length: (inner as NSString).length))
            }
            return
        }
        // Un surlignage par paragraphe (la syntaxe ne traverse pas les retours à la ligne).
        let (o, c) = wrapper(color)
        var segments: [NSRange] = []
        var location = range.location
        while location < NSMaxRange(range) {
            let para = text.paragraphRange(for: NSRange(location: location, length: 0))
            var segment = NSIntersectionRange(para, range)
            let segText = text.substring(with: segment)
            let trimmedLeading = segText.prefix(while: { $0.isWhitespace || $0.isNewline }).utf16.count
            segment.location += trimmedLeading
            segment.length -= trimmedLeading
            while segment.length > 0, let ch = UnicodeScalar(text.character(at: NSMaxRange(segment) - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(ch) { segment.length -= 1 }
            if segment.length > 0 { segments.append(segment) }
            location = NSMaxRange(para)
        }
        guard let first = segments.first, let last = segments.last else { return }
        let whole = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        var rebuilt = ""
        var cursor = whole.location
        for segment in segments {
            rebuilt += text.substring(with: NSRange(location: cursor, length: segment.location - cursor))
            rebuilt += o + text.substring(with: segment) + c
            cursor = NSMaxRange(segment)
        }
        let added = segments.count * ((o as NSString).length + (c as NSString).length)
        replace(whole, with: rebuilt, select: NSRange(location: whole.location + (o as NSString).length, length: whole.length + added - (o as NSString).length - (c as NSString).length))
        sweep(over: selectedRange())
    }

    private func eraseHighlights() {
        let range = selectedRange()
        let found = highlights(touching: range.length > 0 ? range : NSRange(location: range.location, length: 0))
        guard !found.isEmpty else { return }
        let whole = NSRange(location: found.first!.whole.location, length: NSMaxRange(found.last!.whole) - found.first!.whole.location)
        var rebuilt = ""
        var cursor = whole.location
        for h in found {
            rebuilt += text.substring(with: NSRange(location: cursor, length: h.whole.location - cursor))
            rebuilt += text.substring(with: h.inner)
            cursor = NSMaxRange(h.whole)
        }
        replace(whole, with: rebuilt, select: NSRange(location: whole.location, length: (rebuilt as NSString).length))
    }

    // MARK: Styles de paragraphe

    private static let prefixPattern = try! NSRegularExpression(pattern: #"^(#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+|\d+[.)][ \t]+)"#)

    private func setBlock(_ style: BlockStyle) {
        let selection = selectedRange()
        var affected = text.paragraphRange(for: selection)
        // En-tête d'encadré juste au-dessus ?
        var headerAbove = false
        if affected.location > 0 {
            let previous = text.paragraphRange(for: NSRange(location: affected.location - 1, length: 0))
            if text.substring(with: previous).lowercased().hasPrefix("> [!intro]") {
                headerAbove = true
                let nextIsQuote = NSMaxRange(affected) < text.length
                    && text.substring(with: text.paragraphRange(for: NSRange(location: NSMaxRange(affected), length: 0))).hasPrefix(">")
                if style != .intro && !nextIsQuote {
                    affected = NSRange(location: previous.location, length: NSMaxRange(affected) - previous.location)
                    headerAbove = false
                }
            }
        }
        let original = text.substring(with: affected)
        let endsWithNewline = original.hasSuffix("\n")
        var lines = original.components(separatedBy: "\n")
        if endsWithNewline { lines.removeLast() }
        var output: [String] = []
        for line in lines {
            if line.lowercased().hasPrefix("> [!intro]") && style != .intro { continue }
            if line.lowercased().hasPrefix("> [!") { output.append(line); continue }
            let ns = line as NSString
            var content = line
            if let m = Self.prefixPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                content = ns.substring(from: m.range.length)
            }
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                output.append(style == .intro || style == .citation ? ">" : "")
            } else {
                output.append(style.prefix + content)
            }
        }
        if style == .intro && !headerAbove && !(output.first?.lowercased().hasPrefix("> [!intro]") ?? false) {
            output.insert("> [!intro]", at: 0)
        }
        // Les lignes vides de début/fin ne doivent pas devenir des « > ».
        let replacement = output.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        let caretOffset = selection.location - affected.location
        let delta = (replacement as NSString).length - (original as NSString).length
        replace(affected, with: replacement,
                select: NSRange(location: max(affected.location, min(affected.location + caretOffset + max(delta, 0), affected.location + (replacement as NSString).length)), length: 0))
    }
}

extension WritingTextView {
    /// Effet de « reflet » qui balaie un surlignage tout juste posé (désactivé si « Réduire les animations »).
    func sweep(over range: NSRange) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, range.length > 0,
              let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let start = tcm.location(tcm.documentRange.location, offsetBy: range.location),
              let end = tcm.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return }
        wantsLayer = true
        let origin = textContainerOrigin
        tlm.enumerateTextSegments(in: textRange, type: .highlight, options: []) { _, frame, _, _ in
            let rect = frame.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: 1)
            let container = CALayer()
            container.frame = rect
            container.masksToBounds = true
            container.cornerRadius = 4
            container.zPosition = 5
            let sheen = CAGradientLayer()
            sheen.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.75).cgColor,
                            NSColor.white.withAlphaComponent(0).cgColor]
            sheen.startPoint = CGPoint(x: 0, y: 0.5)
            sheen.endPoint = CGPoint(x: 1, y: 0.5)
            sheen.frame = CGRect(x: -60, y: 0, width: 60, height: rect.height)
            container.addSublayer(sheen)
            self.layer?.addSublayer(container)
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = -30
            move.toValue = rect.width + 30
            move.duration = 0.45
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            CATransaction.begin()
            CATransaction.setCompletionBlock { container.removeFromSuperlayer() }
            sheen.add(move, forKey: "balayage")
            sheen.position.x = rect.width + 30
            CATransaction.commit()
            return true
        }
    }
}
