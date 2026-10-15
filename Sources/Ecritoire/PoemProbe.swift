import AppKit
import EcritoireCore

/// Vérifications du mode poème, au pixel près, sans activer l'application.
/// `--poeme-captures dossier` : captures à 100 % et 120 % (haut, milieu, bas) et mesures sur l'image :
/// numéro aligné sur la ligne de base de la 1re ligne, filet du verset actif à la hauteur des lignes, retrait suspendu.
/// `--poeme-edition` : Retour, fusion, suppression et renumérotation, puis contrôle du fichier enregistré (sur une copie).
@MainActor
enum PoemProbe {
    private static func find(_ view: NSView) -> WritingTextView? {
        (view as? WritingTextView) ?? view.subviews.lazy.compactMap(find).first
    }

    private static var failures = 0
    private static func check(_ ok: Bool, _ message: String) {
        print("\(ok ? "✓" : "✗ ÉCHEC") \(message)")
        if !ok { failures += 1 }
    }

    // MARK: Captures et mesures

    static func captures(folder: URL) async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView,
              let tv = find(content), let editor = Workspace.current?.editor else { print("poème: éditeur introuvable"); exit(1) }
        tv.forceCaretForCapture = true
        // Les soulignements du correcteur orthographique fausseraient les mesures d'encre sur l'image.
        tv.isContinuousSpellCheckingEnabled = false
        check(editor.poemDisplay && editor.poemNumbering, "affichage poème activé automatiquement")
        let text = tv.string as NSString
        let verses = Poem.verses(in: tv.string)
        let positions: [(String, Int)] = [("haut", 1), ("milieu", max(1, verses.count / 2 + 1)), ("bas", verses.count)]
        for zoom in [1.0, 1.2] {
            UserDefaults.standard.set(zoom, forKey: "zoom")
            try? await Task.sleep(for: .seconds(0.8))
            for (name, number) in positions {
                guard let verse = Poem.verses(in: tv.string).first(where: { $0.number == number }) else { continue }
                let caret = NSMaxRange(verse.range) - 3
                tv.setSelectedRange(NSRange(location: caret, length: 0))
                if name == "haut" { tv.scroll(.zero) } else if name == "bas" { tv.scroll(NSPoint(x: 0, y: tv.bounds.height)) } else { tv.scrollToShow(caret) }
                try? await Task.sleep(for: .seconds(0.7))
                tv.updateCaret(animated: false)
                // Survol d'un autre verset visible (repère plus léger).
                try? await Task.sleep(for: .seconds(0.2))
                guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
                content.cacheDisplay(in: content.bounds, to: rep)
                let file = folder.appendingPathComponent("poeme-\(Int(zoom * 100))-\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
                measure(tv: tv, rep: rep, content: content, label: "\(Int(zoom * 100)) % \(name)", active: verse.number)
            }
        }
        _ = text
        UserDefaults.standard.set(1.0, forKey: "zoom")
        // Aperçu : fenêtre entière (barre d'outils comprise), un verset actif, un autre survolé.
        try? await Task.sleep(for: .seconds(0.8))
        let list = Poem.verses(in: tv.string)
        if list.count >= 4 {
            let active = list.count * 3 / 5, top = max(0, active - 2), hovered = min(list.count - 1, active + 1)
            tv.setSelectedRange(NSRange(location: NSMaxRange(list[active].range) - 4, length: 0))
            tv.scrollToReadingLine(list[top].range.location, animated: false)
            try? await Task.sleep(for: .seconds(0.6))
            if let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
               let loc = tcm.location(tcm.documentRange.location, offsetBy: list[hovered].range.location + 8),
               let fragment = tlm.textLayoutFragment(for: loc) {
                let f = fragment.layoutFragmentFrame
                tv.updateHover(at: NSPoint(x: tv.textContainerOrigin.x + 60, y: tv.textContainerOrigin.y + f.midY))
            }
            tv.updateCaret(animated: false)
            try? await Task.sleep(for: .seconds(0.4))
            if let frameView = content.superview, let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("poeme-apercu.png"))
            }
        }
        print("poème captures : \(failures) échec(s)")
        NSApp.terminate(nil)
    }

    /// Mesures sur l'image de tous les versets entièrement visibles.
    private static func measure(tv: WritingTextView, rep: NSBitmapImageRep, content: NSView, label: String, active: Int) {
        guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { return }
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width
        let origin = tv.textContainerOrigin
        let visible = tv.visibleRect
        let fontSize = (MarkdownEditor.baseFontSize * CGFloat(UserDefaults.standard.double(forKey: "zoom"))).rounded()
        let verseSize = (fontSize * 1.1).rounded()
        /// Rectangle (vue texte) → pixels de l'image.
        func px(_ r: CGRect) -> CGRect {
            let w = tv.convert(r, to: nil)
            return CGRect(x: w.minX * scale, y: (content.bounds.height - w.maxY) * scale, width: w.width * scale, height: w.height * scale)
        }
        func ink(_ x: Int, _ y: Int) -> CGFloat {
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
            return 1 - min(c.redComponent, c.greenComponent, c.blueComponent) // 0 = blanc
        }
        /// Rangées « encrées » d'une zone (au moins un pixel nettement plus foncé que le fond).
        func rows(_ r: CGRect, threshold: CGFloat) -> [Int: Int] {
            var out: [Int: Int] = [:]
            for y in Int(r.minY)..<Int(r.maxY) {
                var n = 0
                for x in stride(from: Int(r.minX), to: Int(r.maxX), by: 1) where ink(x, y) > threshold { n += 1 }
                if n > 0 { out[y] = n }
            }
            return out
        }
        var numberOffsets: [CGFloat] = []
        var checkedHanging = false
        var fragments: [NSTextLayoutFragment] = []
        // Ce qui est affiché (sans forcer de mise en page)…
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
            fragments.append(fragment)
            return fragment.layoutFragmentFrame.minY + origin.y <= visible.maxY
        }
        let shown = fragments.map { ($0.rangeInElement.location, $0.layoutFragmentFrame.minY) }
        // … ne doit pas bouger après une mise en page complète (sinon le texte est placé sur des hauteurs estimées).
        tlm.ensureLayout(for: tlm.documentRange)
        var drift: CGFloat = 0
        for (location, y) in shown {
            if let now = tlm.textLayoutFragment(for: location) { drift = max(drift, abs(now.layoutFragmentFrame.minY - y)) }
        }
        check(drift < 0.5, "\(label) : mise en page réelle (écart avec la mise en page complète \(Int(drift)) pt)")
        var ends: CGFloat = 0
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.endLocation, options: [.reverse]) { ends = $0.layoutFragmentFrame.maxY; return false }
        check(tv.bounds.height >= ends + origin.y - 1, "\(label) : hauteur de la page couvre tout le texte")
        for fragment in fragments {
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            guard frame.minY >= visible.minY + 4, frame.maxY <= visible.maxY - 4,
                  let paragraph = fragment.textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
                  let number = paragraph.attributedString.attribute(.ecritoireVerse, at: 0, effectiveRange: nil) as? Int,
                  let first = fragment.textLineFragments.first, let last = fragment.textLineFragments.last else { continue }
            let left = origin.x
            // Bande de la 1re ligne.
            let band = CGRect(x: left, y: frame.minY + first.typographicBounds.minY, width: tv.columnWidth, height: first.typographicBounds.height)
            let textRows = rows(px(band), threshold: 0.45)
            let maxCount = textRows.values.max() ?? 0
            // Ligne de base du texte : dernière rangée dense (les jambages sont clairsemés).
            let textBase = textRows.filter { CGFloat($0.value) >= CGFloat(maxCount) * 0.35 }.keys.max()
            // Numéro dans la marge (entre le filet et le bord de page).
            // Le numéro est aligné à droite sur ce bord : la zone le déborde de 6 pt (sans toucher au filet),
            // sinon le jambage droit d'un « 4 » tombe hors de la zone.
            let numberZone = CGRect(x: left - fontSize * 1.1 - 12 - 40, y: band.minY, width: 46, height: band.height)
            let numberRows = rows(px(numberZone), threshold: 0.12)
            let numberBase = numberRows.keys.max()
            if let textBase, let numberBase {
                numberOffsets.append(CGFloat(numberBase - textBase) / scale)
                if ProcessInfo.processInfo.environment["SONDE_DETAIL"] != nil { print("  v. \(number) : numéro \(numberBase), texte \(textBase), rangées \(textRows.sorted { $0.key < $1.key }.suffix(14).map { "\($0.key):\($0.value)" })") }
            } else {
                check(false, "\(label) : v. \(number) numéro \(numberBase == nil ? "absent" : "présent"), texte \(textBase == nil ? "absent" : "présent")")
            }
            // Retrait suspendu : bord gauche de l'encre de la 2e ligne par rapport à la 1re.
            if !checkedHanging, fragment.textLineFragments.count >= 2 {
                let second = fragment.textLineFragments[1]
                func leftInk(_ line: NSTextLineFragment) -> CGFloat? {
                    let r = px(CGRect(x: left - 2, y: frame.minY + line.typographicBounds.minY, width: tv.columnWidth, height: line.typographicBounds.height))
                    for x in Int(r.minX)..<Int(r.maxX) {
                        for y in stride(from: Int(r.minY), to: Int(r.maxY), by: 1) where ink(x, y) > 0.45 { return CGFloat(x) / scale }
                    }
                    return nil
                }
                if let a = leftInk(first), let b = leftInk(second) {
                    let indent = b - a
                    check(abs(indent - verseSize * 1.5) < 4, "\(label) : retrait suspendu v. \(number) = \(Int(indent.rounded())) pt (attendu ≈ \(Int(verseSize * 1.5)))")
                    checkedHanging = true
                }
            }
            // Filet du verset actif : il couvre les lignes de texte, ni plus court ni plus long.
            if number == active {
                let barZone = px(CGRect(x: left - fontSize * 1.1 - 2, y: frame.minY - 10, width: 7, height: frame.height + 20))
                var barRows: [Int] = []
                for y in Int(barZone.minY)..<Int(barZone.maxY) {
                    for x in Int(barZone.minX)..<Int(barZone.maxX) {
                        if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.blueComponent - c.greenComponent > 0.12 { barRows.append(y); break }
                    }
                }
                let textAll = rows(px(CGRect(x: left, y: frame.minY + first.typographicBounds.minY, width: tv.columnWidth,
                                            height: last.typographicBounds.maxY - first.typographicBounds.minY)), threshold: 0.45)
                if let bt = barRows.min(), let bb = barRows.max(), let tt = textAll.keys.min(), let tb = textAll.keys.max() {
                    let top = CGFloat(bt - tt) / scale, bottom = CGFloat(tb - bb) / scale
                    // Tolérance de 9 pt à 100 %, proportionnelle au zoom (les accents montent avec la taille du texte).
                    let tolerance = 9 * fontSize / MarkdownEditor.baseFontSize
                    check(abs(top) < tolerance && abs(bottom) < tolerance,
                          "\(label) : filet v. \(number) de \(Int(top.rounded())) pt sous le haut du texte, \(Int(bottom.rounded())) pt au-dessus du bas (\(fragment.textLineFragments.count) lignes)")
                } else {
                    check(false, "\(label) : filet du verset actif v. \(number) introuvable")
                }
            }
        }
        if !numberOffsets.isEmpty {
            let worst = numberOffsets.map(abs).max() ?? 0
            check(worst <= 1.0, "\(label) : \(numberOffsets.count) numéros sur la ligne de base de leur 1re ligne (écart max \(String(format: "%.1f", worst)) pt)")
        }
        _ = tcm
    }

    // MARK: Édition

    static func editing() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView,
              let tv = find(content), let editor = Workspace.current?.editor, let url = editor.url else { print("poème: éditeur introuvable"); exit(1) }
        func verses() -> [Poem.Verse] { Poem.verses(in: tv.string) }
        func settle() async { try? await Task.sleep(for: .seconds(1.0)) }
        check(tv.poemEditing, "édition des versets active")
        let before = verses().count
        let originalHeader = (tv.string as NSString).substring(to: Poem.headerEnd(in: tv.string as NSString))

        // Curseur posé au tout début d'un verset : il saute après le numéro masqué.
        let v10 = verses()[min(9, verses().count - 1)]
        tv.setSelectedRange(NSRange(location: v10.range.location, length: 0))
        check(tv.selectedRange().location == NSMaxRange(v10.marker!), "curseur jamais dans le numéro masqué")

        // Retour à la fin du verset 3 : un nouveau verset 4, les suivants décalés.
        let v3 = verses()[2]
        let v3Text = v3.text
        tv.setSelectedRange(NSRange(location: NSMaxRange(v3.range), length: 0))
        tv.insertNewline(nil)
        tv.insertText("Verset ajouté par la vérification.", replacementRange: tv.selectedRange())
        await settle()
        var list = verses()
        check(list.count == before + 1 && list[3].text == "Verset ajouté par la vérification.", "Retour : nouveau verset 4")
        check(Poem.renumberEdits(tv.string).isEmpty && list.last?.number == before + 1, "versets suivants renumérotés (\(list.last?.number ?? 0))")

        // Effacer au début du verset 4 : fusion avec le verset 3.
        tv.setSelectedRange(NSRange(location: NSMaxRange(list[3].marker!), length: 0))
        tv.deleteBackward(nil)
        await settle()
        list = verses()
        check(list.count == before && list[2].text == v3Text + "Verset ajouté par la vérification.", "Effacer : verset fusionné avec le précédent")
        check(Poem.renumberEdits(tv.string).isEmpty, "numéros recalés après la fusion")

        // Suppression du verset 5 : son texte, puis son numéro.
        let v5 = list[4]
        let v6Text = list[5].text
        tv.setSelectedRange(NSRange(location: NSMaxRange(v5.marker!), length: NSMaxRange(v5.range) - NSMaxRange(v5.marker!)))
        tv.deleteBackward(nil)
        tv.deleteBackward(nil)
        await settle()
        list = verses()
        check(list.count == before - 1 && list[4].text == v6Text, "suppression d'un verset : le 6 devient le 5")
        check(Poem.renumberEdits(tv.string).isEmpty, "numéros recalés après la suppression")

        // Enregistrement : texte tel quel, sans en-tête YAML, numéros à jour.
        editor.flush()
        let saved = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(!saved.hasPrefix("---"), "aucun en-tête YAML ajouté")
        check(saved == tv.string, "le fichier enregistré est le texte affiché")
        check(saved.hasPrefix(originalHeader), "en-tête du poème intact")
        check(Poem.renumberEdits(saved).isEmpty && Poem.verses(in: saved).count == before - 1, "fichier renuméroté (\(Poem.verses(in: saved).count) versets)")
        print("poème édition : \(failures) échec(s)")
        NSApp.terminate(nil)
    }
}
