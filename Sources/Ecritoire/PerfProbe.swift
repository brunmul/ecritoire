import AppKit
import EcritoireCore

/// Mesure de fluidité (`--perf N`) : frappe, déplacement du curseur et défilement sur le document ouvert,
/// mise à jour de l'interface comprise. Affiche médiane, p95 et maximum, puis quitte.
@MainActor
enum PerfProbe {
    static func run(keystrokes: Int) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView,
              let textView = find(content) else {
            print("perf: éditeur introuvable"); NSApp.terminate(nil); return
        }
        window.makeFirstResponder(textView)
        let length = (textView.string as NSString).length
        print("perf: document de \(length) caractères")
        textView.setSelectedRange(NSRange(location: length / 2, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        settle(window)

        func measure(_ label: String, _ count: Int, _ step: (Int) -> Void) {
            var times: [Double] = []
            for i in 0..<count {
                let t0 = CACurrentMediaTime()
                step(i)
                settle(window)
                times.append((CACurrentMediaTime() - t0) * 1000)
            }
            times.sort()
            let median = times[times.count / 2], p95 = times[Int(Double(times.count) * 0.95)], max = times.last ?? 0
            print(String(format: "perf: %@ — médiane %.1f ms, p95 %.1f ms, max %.1f ms (%d essais)", label, median, p95, max, count))
        }
        measure("frappe", keystrokes) { _ in textView.insertText("a", replacementRange: textView.selectedRange()) }
        measure("curseur ↓", keystrokes) { _ in textView.moveDown(nil) }
        measure("défilement", keystrokes) { _ in
            guard let clip = textView.enclosingScrollView?.contentView else { return }
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + 40))
            textView.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        measure("défilement retour (déjà mis en page)", keystrokes) { _ in
            guard let clip = textView.enclosingScrollView?.contentView else { return }
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y - 40))
            textView.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        measure("défilement sans affichage", keystrokes) { _ in
            guard let clip = textView.enclosingScrollView?.contentView else { return }
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + 2400 / Double(keystrokes) * 3))
            textView.enclosingScrollView?.reflectScrolledClipView(clip)
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        // Annule la frappe de test.
        textView.undoManager?.removeAllActions()
        exit(0)
    }

    /// Laisse SwiftUI et AppKit traiter les mises à jour en attente, puis force l'affichage.
    private static func settle(_ window: NSWindow) {
        RunLoop.main.run(mode: .default, before: Date())
        window.displayIfNeeded()
        CATransaction.flush()
    }

    private static func find(_ view: NSView) -> WritingTextView? {
        if let tv = view as? WritingTextView { return tv }
        return view.subviews.lazy.compactMap(find).first
    }
}

/// Démonstration automatique (`--demo image.png`) : applique quelques commandes d'édition au début
/// du document, vérifie le Markdown produit, laisse une sélection avec sa bulle, capture la fenêtre.
@MainActor
enum DemoProbe {
    static func run(output: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView,
              let tv = find(content) else { print("demo: éditeur introuvable"); exit(1) }
        window.makeFirstResponder(tv)
        // Hors événements réels, les groupes d'annulation automatiques ne se ferment pas : on s'en remet
        // aux groupes explicites de chaque commande.
        tv.undoManager?.groupsByEvent = false
        let text = { tv.string as NSString }
        func select(_ word: String) -> Bool {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05)) // sépare les étapes d'annulation
            let r = text().range(of: word)
            guard r.location != NSNotFound else { print("demo: « \(word) » introuvable"); return false }
            tv.setSelectedRange(r)
            return true
        }
        func paragraph(containing word: String) -> String {
            let r = text().range(of: word)
            guard r.location != NSNotFound else { return "?" }
            return text().substring(with: text().paragraphRange(for: r)).trimmingCharacters(in: .newlines)
        }
        var ok = true
        func check(_ label: String, _ condition: Bool) {
            print("demo: \(condition ? "✓" : "✗") \(label)")
            if !condition { ok = false }
        }

        if select("le bon sens ou la raison") { tv.perform(.highlight(.jaune)) }
        check("surlignage jaune ==…==", paragraph(containing: "bon sens ou la raison").contains("==le bon sens ou la raison=="))
        if select("diverses voies") { tv.perform(.highlight(.vert)) }
        check("surlignage vert <mark>", paragraph(containing: "diverses voies").contains(#"<mark class="vert">diverses voies</mark>"#))
        if select("diverses voies") { tv.perform(.highlight(.vert)) }
        check("re-cliquer la même couleur retire le surlignage", !paragraph(containing: "diverses voies").contains("<mark"))
        if select("le droit chemin") { tv.perform(.bold) }
        check("gras", paragraph(containing: "le droit chemin").contains("**le droit chemin**"))
        if select("le droit chemin") { tv.perform(.bold) }
        check("gras retiré", !paragraph(containing: "le droit chemin").contains("**le droit"))
        if select("géomètres") { tv.perform(.italic) }
        check("italique", paragraph(containing: "géomètres").contains("*géomètres*"))
        if select("car chacun pense") { tv.perform(.block(.citation)) }
        check("intro → citation", paragraph(containing: "car chacun pense").hasPrefix("> Le bon sens"))
        if select("car chacun pense") { tv.perform(.block(.intro)) }
        check("citation → intro", text().substring(to: min(text().length, 2000)).contains("> [!intro]\n> Le bon sens"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        tv.undoManager?.undo()
        check("annuler (⌘Z) revient en arrière", paragraph(containing: "car chacun pense").hasPrefix("> Le bon sens"))
        check("le surlignage jaune est toujours là", paragraph(containing: "bon sens ou la raison").contains("==le bon sens"))

        // Défilement aimanté : après un arrêt quelconque, le haut de l'écran doit tomber sur un début de paragraphe.
        if let scroll = tv.enclosingScrollView as? PageScrollView, let tlm = tv.textLayoutManager {
            var snapped = 0
            // Douze arrêts répartis entre 20 % et 80 % de la hauteur du document.
            let height = Double(tv.bounds.height)
            for y in stride(from: height * 0.2, to: height * 0.8, by: height * 0.05) {
                scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                tlm.textViewportLayoutController.layoutViewport()
                scroll.snapToParagraph()
                RunLoop.main.run(until: Date().addingTimeInterval(0.35))
                let probe = scroll.contentView.bounds.minY + 28 - tv.textContainerOrigin.y
                if let f = tlm.textLayoutFragment(for: CGPoint(x: 0, y: probe + 0.5)), abs(f.layoutFragmentFrame.minY - probe) < 1.5 { snapped += 1 }
            }
            print("demo: défilement aimanté — \(snapped)/12 arrêts calés sur un début de paragraphe (les autres tombent au milieu d'un long paragraphe)")
        }
        // Laisse une sélection visible avec sa bulle pour la capture.
        _ = select("longues chaînes de raisons")
        tv.scrollRangeToVisible(tv.selectedRange())
        tv.scheduleBubble()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output)
            }
            print("demo: \(ok ? "tout est bon" : "ÉCHECS")")
            exit(ok ? 0 : 1)
        }
    }

    private static func find(_ view: NSView) -> WritingTextView? {
        if let tv = view as? WritingTextView { return tv }
        return view.subviews.lazy.compactMap(find).first
    }
}

/// Scénario complet (`--revue image.png`) : commentaires, prompt pour Claude, modification externe,
/// relecture des modifications. Écrit dans le classeur ouvert : à lancer sur une copie.
@MainActor
enum ReviewProbe {
    static func run(output: URL, workspace: Workspace) async {
        setvbuf(stdout, nil, _IONBF, 0)
        let editor = workspace.editor
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView,
              let tv = find(content), let url = editor.url, let root = editor.binderRoot else {
            print("revue: éditeur introuvable"); exit(1)
        }
        tv.undoManager?.groupsByEvent = false
        var ok = true
        func check(_ label: String, _ condition: Bool) {
            print("revue: \(condition ? "✓" : "✗") \(label)")
            if !condition { ok = false }
        }
        // Vraies pauses (la file principale continue de tourner : sauvegarde, FSEvents, calculs en arrière-plan).
        func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        let text = { tv.string as NSString }

        // 1. Deux commentaires.
        tv.setSelectedRange(text().range(of: "le bon sens ou la raison"))
        tv.perform(.comment)
        check("brouillon de commentaire ouvert", editor.comments.draftRange != nil && editor.commentsPanelVisible)
        editor.comments.draftText = "Préciser : bon sens et raison, est-ce la même chose ?"
        editor.comments.commitDraft()
        tv.setSelectedRange(text().range(of: "Les plus grandes âmes sont capables"))
        tv.perform(.comment)
        editor.comments.draftText = "Phrase trop longue, la couper en deux."
        editor.comments.commitDraft()
        check("2 commentaires enregistrés", Sidecar.loadComments(for: url, in: root).count == 2)

        // 2. On écrit avant les passages commentés : les commentaires suivent.
        tv.setSelectedRange(NSRange(location: text().range(of: "Le bon sens est la chose").location, length: 0))
        tv.undoManager?.beginUndoGrouping()
        tv.insertText("Préambule ajouté. ", replacementRange: tv.selectedRange())
        tv.undoManager?.endUndoGrouping()
        await pause(1.2) // sauvegarde automatique
        let first = editor.comments.visibleComments.first!
        let r = editor.comments.ranges[first.id]!
        check("le commentaire suit le texte après une insertion", text().substring(with: r) == "le bon sens ou la raison")
        if text().substring(with: r) != "le bon sens ou la raison" { print("revue:   trouvé « \(text().substring(with: r)) » en \(r), quote=\(first.quote)") }

        editor.comments.select(first.id)
        await pause(0.8)
        if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: output.deletingPathExtension().appendingPathExtension("commentaires.png"))
        }
        // 3. Prompt pour Claude + instantané.
        let prompt = editor.claudePrompt()
        check("prompt : consignes, 2 commentaires, texte intégral",
              prompt.contains("## Consignes") && prompt.contains("### 1. « le bon sens ou la raison »")
              && prompt.contains("### 2. « Les plus grandes âmes sont capables »") && prompt.contains("Préambule ajouté."))
        if !prompt.contains("### 1. « le bon sens") { print("revue:   prompt = \(prompt.prefix(1500))") }
        editor.takeSnapshot()
        check("instantané créé", Sidecar.loadSnapshot(for: url, in: root) != nil)

        // 4. « Claude » modifie le fichier sur le disque.
        var file = try! String(contentsOf: url, encoding: .utf8)
        file = file.replacingOccurrences(of: "le bon sens ou la raison,", with: "le bon sens ou la raison (le jugement),")
        file = file.replacingOccurrences(of: "Préambule ajouté. ", with: "")
        file = file.replacingOccurrences(of: "Les plus grandes âmes sont capables", with: "Les plus grandes âmes sont aussi capables")
        try! file.write(to: url, atomically: true, encoding: .utf8)
        await pause(1.5)
        check("modification extérieure détectée et rechargée", tv.string.contains("(le jugement)"))
        check("bandeau : modifications depuis l'instantané", (editor.pendingChanges ?? 0) >= 3)
        check("commentaire 1 toujours ancré", editor.comments.ranges[first.id] != nil)

        // 5. Relecture.
        editor.enterReview()
        await pause(0.8)
        let count = editor.review?.changes.count ?? 0
        check("mode Modifications : \(count) modifications", count >= 3)
        check("texte supprimé visible dans la vue fusionnée", tv.string.contains("Préambule ajouté."))
        check("lecture seule pendant la relecture", !tv.isEditable)
        // Capture pendant la relecture, commentaires ouverts.
        editor.selectChange(min(1, count - 1))
        await pause(0.6)
        if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: output)
        }
        // Refuser la suppression du préambule : il revient dans le fichier.
        if let i = editor.review?.changes.firstIndex(where: { $0.hunk.deleted.contains("Préambule") }) {
            editor.selectChange(i)
            await pause(0.2)
            editor.rejectCurrentChange()
            await pause(0.8)
        }
        check("refuser : le texte d'avant revient dans le fichier", (try? String(contentsOf: url, encoding: .utf8))?.contains("Préambule ajouté.") == true)
        editor.acceptAllChanges()
        await pause(0.4)
        check("tout accepter : plus d'instantané, fin de la relecture", Sidecar.loadSnapshot(for: url, in: root) == nil && editor.review == nil)
        await pause(0.5)
        check("le fichier garde les modifications acceptées", (try? String(contentsOf: url, encoding: .utf8))?.contains("sont aussi capables") == true)
        print("revue: \(ok ? "tout est bon" : "ÉCHECS")")
        exit(ok ? 0 : 1)
    }

    private static func find(_ view: NSView) -> WritingTextView? {
        if let tv = view as? WritingTextView { return tv }
        return view.subviews.lazy.compactMap(find).first
    }
}

/// Vérifie la progression du sommaire et la navigation par ses barres (`--sommaire image.png`).
@MainActor
enum OutlineProbe {
    static func run(output: URL, workspace: Workspace) async {
        setvbuf(stdout, nil, _IONBF, 0)
        let editor = workspace.editor, live = editor.live
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView,
              let tv = find(content) else { print("sommaire: éditeur introuvable"); exit(1) }
        var ok = true
        func check(_ label: String, _ condition: Bool) {
            print("sommaire: \(condition ? "✓" : "✗") \(label)")
            if !condition { ok = false }
        }
        try? await Task.sleep(for: .seconds(0.5))
        check("titres trouvés (\(live.headings.count))", live.headings.count >= 4)
        guard live.headings.count >= 4 else { exit(1) }
        // Navigation au milieu de la 4e section, comme un glisser sur sa barre.
        let (a, b) = live.sectionBounds(3)
        editor.scrollHandler?(a + (b - a) / 2, false)
        try? await Task.sleep(for: .seconds(0.4))
        check("section en cours = 4 (\(live.readingIndex.map { $0 + 1 } ?? 0))", live.readingIndex == 3)
        check("progression ≈ 50 % (\(Int(live.readingProgress * 100)) %)", abs(live.readingProgress - 0.5) < 0.2)
        editor.scrollHandler?(a + Int(Double(b - a) * 0.9), false)
        try? await Task.sleep(for: .seconds(0.4))
        check("progression suit le défilement (\(Int(live.readingProgress * 100)) %)", live.readingProgress > 0.7)
        check("index de la règle ≈ position dans le document (\(Int(live.readingFraction * 1000)) ‰)",
              abs(live.readingFraction - Double(a + Int(Double(b - a) * 0.9)) / Double(live.characterCount)) < 0.03)
        check("graduations de paragraphes (\(live.paragraphs.count))", live.paragraphs.count > 20)
        let geo = RulerGeometry(headings: live.headings, paragraphs: live.paragraphs, length: live.characterCount,
                                height: 900, rowHeight: OutlineRuler.rowHeight)
        let ys = live.headings.indices.compactMap { geo.tickY(heading: $0) }
        check("crans de titres espacés d'au moins une ligne", zip(ys, ys.dropFirst()).allSatisfy { $1 - $0 >= OutlineRuler.rowHeight - 0.5 })
        var worst = 0
        for p in live.paragraphs where p >= (live.headings.first?.id ?? 0) { worst = max(worst, abs(geo.location(for: geo.y(for: p)) - p)) }
        check("règle : aller-retour position → hauteur → position (écart max \(worst))", worst < 40)
        check("un titre est sur son cran", live.headings.indices.allSatisfy { abs(geo.y(for: live.headings[$0].id) - geo.tickY(heading: $0)!) < 0.5 })
        // Paragraphe du curseur mis en avant.
        if let loc = tv.readingLocation() {
            window.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: loc + 5, length: 0))
        }
        try? await Task.sleep(for: .seconds(0.5))
        // Le filet du paragraphe du curseur est dessiné par le texte : son paragraphe porte la marque ecritoireFocus.
        let caret = tv.selectedRange().location
        let focused = caret < (tv.textStorage?.length ?? 0) && tv.textStorage?.attribute(.ecritoireFocus, at: caret, effectiveRange: nil) != nil
        check("paragraphe du curseur mis en avant (filet)", focused)
        if !focused { print("sommaire:   premier répondeur : \(window.firstResponder === tv), éditable : \(tv.isEditable), sélection : \(tv.selectedRange())") }
        if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: output)
        }
        print("sommaire: \(ok ? "tout est bon" : "ÉCHECS")")
        exit(ok ? 0 : 1)
    }

    private static func find(_ view: NSView) -> WritingTextView? {
        if let tv = view as? WritingTextView { return tv }
        return view.subviews.lazy.compactMap(find).first
    }
}


/// Curseur : capture de zones autour du point d'insertion dans plusieurs situations (`--curseur dossier`).
@MainActor
enum CaretProbe {
    static func run(folder: URL) async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView,
              let tv = find(content), let editor = Workspace.current?.editor else { print("curseur: éditeur introuvable"); exit(1) }
        tv.forceCaretForCapture = true
        let text = tv.string as NSString
        func loc(_ needle: String, end: Bool = false) -> Int? {
            let r = text.range(of: needle)
            return r.location == NSNotFound ? nil : (end ? NSMaxRange(r) : r.location + 3)
        }
        let cases: [(String, Int?)] = [
            ("corps", loc("En quoi il n’est pas")),
            ("fin-de-paragraphe", loc("qui courent et qui s’en éloignent.", end: true)),
            ("titre", loc("Deuxième partie")),
            ("apres-image", text.range(of: "\n", options: [], range: NSRange(location: text.range(of: "![[").location, length: 2000)).location + 1),
            ("fin-du-document", text.length),
        ]
        for zoom in [0.7, 1.0, 1.5] {
            UserDefaults.standard.set(zoom, forKey: "zoom")
            try? await Task.sleep(for: .seconds(0.6))
            for (name, location) in cases {
                guard let location else { print("curseur: \(name) introuvable"); continue }
                window.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: location, length: 0))
                tv.scrollToShow(location)
                try? await Task.sleep(for: .seconds(0.5))
                tv.updateCaret(animated: false)
                try? await Task.sleep(for: .seconds(0.1))
                let caret = tv.caretLayer.frame
                let rectInWindow = tv.convert(caret, to: nil)
                guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                // Découpe autour du curseur.
                let scale = CGFloat(rep.pixelsWide) / view.bounds.width
                let cx = rectInWindow.midX * scale, cy = (view.bounds.height - rectInWindow.midY) * scale
                let crop = CGRect(x: max(0, cx - 220), y: max(0, cy - 90), width: 440, height: 180)
                if let cg = rep.cgImage?.cropping(to: crop) {
                    let out = NSBitmapImageRep(cgImage: cg)
                    try? out.representation(using: .png, properties: [:])?
                        .write(to: folder.appendingPathComponent("curseur-\(Int(zoom * 100))-\(name).png"))
                }
                print("curseur: \(Int(zoom * 100)) % \(name) → \(caret.integral)")
            }
        }
        // Le filet du paragraphe reste-t-il affiché après frappe, déplacement et attente ?
        UserDefaults.standard.set(1.0, forKey: "zoom")
        try? await Task.sleep(for: .seconds(0.6))
        if let start = cases[0].1 {
            tv.setSelectedRange(NSRange(location: start, length: 0))
            for ch in ["a", "b", "c"] {
                tv.undoManager?.beginUndoGrouping()
                tv.insertText(ch, replacementRange: tv.selectedRange())
                tv.undoManager?.endUndoGrouping()
                try? await Task.sleep(for: .seconds(0.15))
            }
            tv.moveDown(nil)
            try? await Task.sleep(for: .seconds(2.0))
            let bar = tv.paragraphBar
            let presentation = bar.presentation() ?? bar
            print("curseur: filet après frappe + 2 s → affiché \(tv.paragraphShown), opacité \(presentation.opacity), attaché \(bar.superlayer != nil), hauteur \(Int(bar.frame.height))")
        }
        _ = editor
        exit(0)
    }

    private static func find(_ view: NSView) -> WritingTextView? {
        if let tv = view as? WritingTextView { return tv }
        return view.subviews.lazy.compactMap(find).first
    }
}

/// Décalage du curseur et du filet (`--decalage`) : compare notre position avec le rectangle du système,
/// en haut, au milieu et en bas du document, à plusieurs zooms, juste après le placement et 1 s plus tard.
@MainActor
enum OffsetProbe {
    static func run() async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView,
              let tv = find(content) else { print("décalage: éditeur introuvable"); exit(1) }
        tv.forceCaretForCapture = true
        window.makeFirstResponder(tv)
        func systemRect(_ loc: Int) -> CGRect {
            let r = tv.firstRect(forCharacterRange: NSRange(location: loc, length: 1), actualRange: nil)
            return tv.convert(window.convertFromScreen(r), from: nil)
        }
        for zoom in [1.0, 1.2, 1.5] {
            UserDefaults.standard.set(zoom, forKey: "zoom")
            try? await Task.sleep(for: .seconds(0.8))
            let text = tv.string as NSString
            for fraction in [0.02, 0.3, 0.6, 0.9, 0.99] {
                // Début d'un mot au milieu d'un paragraphe de corps, vers cette position.
                var loc = Int(Double(text.length) * fraction)
                let para = text.paragraphRange(for: NSRange(location: loc, length: 0))
                loc = min(para.location + 10, NSMaxRange(para) - 1)
                tv.setSelectedRange(NSRange(location: loc, length: 0))
                tv.scrollToShow(loc)
                try? await Task.sleep(for: .seconds(0.4))
                tv.updateCaret(animated: false)
                let now = tv.caretLayer.frame
                let sys = systemRect(loc)
                // Défilement jusqu'en haut puis retour : met en page tout le texte au-dessus.
                if let clip = tv.enclosingScrollView?.contentView {
                    let saved = clip.bounds.origin
                    var y = saved.y
                    while y > 0 {
                        y = max(0, y - 1500)
                        clip.scroll(to: NSPoint(x: 0, y: y)); tv.enclosingScrollView?.reflectScrolledClipView(clip)
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    tv.scrollToShow(loc)
                }
                try? await Task.sleep(for: .seconds(1.0))
                let later = tv.caretLayer.frame
                let sysLater = systemRect(loc)
                let bar = tv.paragraphBar.frame
                let paraTop = systemRect(para.location).minY
                print(String(format: "décalage: zoom %3.0f %% pos %2.0f %% → curseur x %+.1f y %+.1f (après 1 s : x %+.1f y %+.1f, recalcul %+.1f) ; filet haut %+.1f",
                             zoom * 100, fraction * 100, now.minX - sys.minX, now.maxY - sys.maxY,
                             later.minX - sysLater.minX, later.maxY - sysLater.maxY, sysLater.maxY - sys.maxY, bar.minY - paraTop))
            }
        }
        exit(0)
    }

    private static func find(_ view: NSView) -> WritingTextView? {
        if let tv = view as? WritingTextView { return tv }
        return view.subviews.lazy.compactMap(find).first
    }
}


/// Parcours réel (`--parcours dossier`) : clic simulé dans un paragraphe sans défilement préalable, puis au milieu
/// et en bas après défilement ; vérité terrain par les pixels de la capture (lignes réellement dessinées).
@MainActor
enum JourneyProbe {
    static func run(folder: URL) async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView,
              let tv = find(content), let scroll = tv.enclosingScrollView else { print("parcours: éditeur introuvable"); exit(1) }
        tv.forceCaretForCapture = true
        let zoomLabel = Int((UserDefaults.standard.double(forKey: "zoom") == 0 ? 1 : UserDefaults.standard.double(forKey: "zoom")) * 100)
        for (name, fraction) in [("haut", -1.0), ("milieu", 0.5), ("bas", 0.95)] {
            if fraction >= 0 {
                // Défilement par paliers, comme une molette.
                let target = (tv.bounds.height - scroll.contentView.bounds.height) * fraction
                var y = scroll.contentView.bounds.minY
                while abs(y - target) > 1 {
                    y += max(-900, min(900, target - y))
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                    try? await Task.sleep(for: .milliseconds(25))
                }
                try? await Task.sleep(for: .seconds(0.4))
            }
            // Clic au milieu de la colonne, à 40 % de la hauteur visible.
            let visible = scroll.contentView.bounds
            let clickInView = NSPoint(x: tv.textContainerOrigin.x + (tv.textContainer?.size.width ?? 400) * 0.45,
                                      y: visible.minY + visible.height * (name == "haut" ? 0.8 : 0.4))
            // Équivalent d'un clic : position d'insertion sous ce point (le clic synthétique n'atteint pas
            // une fenêtre d'arrière-plan).
            window.makeFirstResponder(tv)
            var index = 0
            if let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
               let fragment = tlm.textLayoutFragment(for: CGPoint(x: 10, y: clickInView.y - tv.textContainerOrigin.y)) {
                index = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
                let again = tlm.textLayoutFragment(for: fragment.rangeInElement.location)
                let fragText = (fragment.textElement as? NSTextParagraph)?.attributedString.string.prefix(40) ?? "?"
                let storeText = (tv.string as NSString).substring(with: NSRange(location: index, length: min(40, (tv.string as NSString).length - index)))
                print("parcours:   début du fragment \(index) : fragment « \(fragText) » / texte « \(storeText) »")
                print("parcours:   point y \(Int(clickInView.y - tv.textContainerOrigin.y)) → fragment y \(Int(fragment.layoutFragmentFrame.minY))–\(Int(fragment.layoutFragmentFrame.maxY)) ; même fragment par position : y \(Int(again?.layoutFragmentFrame.minY ?? -1)), identique \(again === fragment)")
            }
            // On vise un vrai paragraphe de corps (pas une ligne vide, une image ou un titre).
            let text = tv.string as NSString
            var guardCount = 0
            while guardCount < 50 {
                guardCount += 1
                let para = text.paragraphRange(for: NSRange(location: min(index, text.length), length: 0))
                let line = text.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.count > 120 && !line.hasPrefix("#") && !line.hasPrefix("!") && !line.hasPrefix(">") {
                    index = para.location + min(40, para.length - 1)
                    break
                }
                index = NSMaxRange(para)
            }
            tv.setSelectedRange(NSRange(location: index, length: 0))
            try? await Task.sleep(for: .seconds(0.9))
            if let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
               let f2 = tlm.textLayoutFragment(for: CGPoint(x: 10, y: clickInView.y - tv.textContainerOrigin.y)) {
                let start = tcm.offset(from: tcm.documentRange.location, to: f2.rangeInElement.location)
                print("parcours:   après sélection, au même point : fragment \(start) y \(Int(f2.layoutFragmentFrame.minY)) « \((f2.textElement as? NSTextParagraph)?.attributedString.string.prefix(30) ?? "?") » ; viewport \(tlm.textViewportLayoutController.viewportBounds.integral)")
            }
            let attrs = tv.textStorage?.attributes(at: index, effectiveRange: nil) ?? [:]
            print("parcours:   index \(index), focus attr \(attrs[.ecritoireFocus] != nil), caret \(tv.caretLayer.frame.integral), visible y \(Int(scroll.contentView.bounds.minY))–\(Int(scroll.contentView.bounds.maxY))")
            tv.caretLayer.removeAllAnimations() // pas de « respiration » au moment de la capture
            tv.caretLayer.opacity = 1
            try? await Task.sleep(for: .milliseconds(50))
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("parcours-\(zoomLabel)-\(name).png"))
            analyse(rep: rep, view: view, tv: tv, name: "\(zoomLabel) % \(name)")
        }
        exit(0)
    }

    /// Lignes de texte = bandes de rangées contenant des pixels sombres dans la colonne de texte.
    private static func analyse(rep: NSBitmapImageRep, view: NSView, tv: WritingTextView, name: String) {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let colLeft = tv.convert(NSPoint(x: tv.textContainerOrigin.x, y: 0), to: view)
        let colRight = tv.convert(NSPoint(x: tv.textContainerOrigin.x + (tv.textContainer?.size.width ?? 400), y: 0), to: view)
        let x0 = Int(colLeft.x * scale) + 4, x1 = Int(colRight.x * scale) - 4
        let h = rep.pixelsHigh
        func color(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
            let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        var dark = [Bool](repeating: false, count: h)
        for y in 0..<h {
            var n = 0
            var x = x0
            while x < x1 { let (r, g, b) = color(x, y); if (r + g + b) / 3 < 0.45 { n += 1 }; x += 2 }
            dark[y] = n >= 2
        }
        var bands: [(Int, Int)] = []
        var y = 0
        while y < h { if dark[y] { let s = y; while y < h && dark[y] { y += 1 }; bands.append((s, y - 1)) } else { y += 1 } }
        // Filet : colonne à gauche de la colonne de texte, pixels lavande (bleu > rouge > vert, saturés).
        var barRows: [Int] = []
        let barSearch = max(0, x0 - Int(60 * scale))..<max(0, x0 - 4)
        for y in 0..<h {
            for x in stride(from: barSearch.lowerBound, to: barSearch.upperBound, by: 1) {
                let (r, g, b) = color(x, y)
                if b - g > 0.12 && r - g > 0.03 && (r + g + b) / 3 < 0.8 { barRows.append(y); break }
            }
        }
        guard let barTop = barRows.first, let barBottom = barRows.last else { print("parcours: \(name) → aucun filet visible"); return }
        // Lignes chevauchant le filet, et lignes du paragraphe (groupe de bandes autour du filet).
        let inside = bands.filter { $0.1 >= barTop && $0.0 <= barBottom }
        let before = bands.last { $0.1 < barTop }
        let after = bands.first { $0.0 > barBottom }
        let firstLine = inside.first, lastLine = inside.last
        let lineHeight = inside.count > 1 ? Double(inside[1].0 - inside[0].0) : 40
        func pt(_ px: Int) -> String { String(format: "%.1f", Double(px) / Double(scale)) }
        print("parcours: \(name) → filet \(pt(barTop))–\(pt(barBottom)) pt, \(inside.count) lignes dedans ; "
              + "haut du filet vs 1re ligne : \(firstLine.map { pt(barTop - $0.0) } ?? "?") pt ; "
              + "bas du filet vs dernière ligne : \(lastLine.map { pt($0.1 - barBottom) } ?? "?") pt ; "
              + "marge avec la ligne d'avant : \(before.map { pt(barTop - $0.1) } ?? "-") pt, d'après : \(after.map { pt($0.0 - barBottom) } ?? "-") pt (interligne \(String(format: "%.0f", lineHeight / Double(scale))) pt)")
        // Curseur : rangées lavande plein dans la colonne de texte.
        var caretRows: [Int] = []
        for y in 0..<h {
            var x = x0
            while x < x1 { let (r, g, b) = color(x, y); if b - g > 0.25 && r - g > 0.1 { caretRows.append(y); break }; x += 1 }
        }
        if let ct = caretRows.first, let cb = caretRows.last {
            let mid = (ct + cb) / 2
            let line = bands.first { $0.0 <= mid && $0.1 >= mid }
            print("parcours: \(name) → curseur \(pt(ct))–\(pt(cb)) pt, \(line != nil ? "sur une ligne de texte (\(pt(line!.0))–\(pt(line!.1)) pt)" : "HORS de toute ligne")")
        }
    }

    private static func find(_ view: NSView) -> WritingTextView? {
        if let tv = view as? WritingTextView { return tv }
        return view.subviews.lazy.compactMap(find).first
    }
}
