import AppKit
import EcritoireCore

/// `--commentaires-circuit dossier` : circuit des commentaires sur une copie de document, sans activer l'application.
/// Volet jamais ouvert à vide, accumulation, envoi à Claude (prompt écrit dans le dossier, pas dans le presse-papiers),
/// archivage (soulignements retirés, mesurés sur l'image), archives, restauration, bouton/raccourci, réouverture.
@MainActor
enum CommentsProbe {
    private static var failures = 0
    private static func check(_ ok: Bool, _ message: String) {
        print("\(ok ? "✓" : "✗ ÉCHEC") \(message)")
        if !ok { failures += 1 }
    }

    private static func find<T: NSView>(_ view: NSView, _ type: T.Type) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { find($0, type) }.first
    }

    static func run(folder: URL) async {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let content = window.contentView,
              let tv = find(content, WritingTextView.self), let editor = Workspace.current?.editor,
              let url = editor.url, let root = editor.binderRoot else { print("commentaires: éditeur introuvable"); exit(1) }
        let store = editor.comments
        let original = try? String(contentsOf: url, encoding: .utf8)
        func settle(_ s: Double = 0.7) async { try? await Task.sleep(for: .seconds(s)) }
        func snapshot(_ name: String) -> NSBitmapImageRep? {
            guard let frame = content.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
            return rep
        }
        /// Volet visible à l'écran : la zone de texte s'arrête bien avant le bord droit de la fenêtre.
        func panelOnScreen() -> Bool {
            guard let scroll = tv.enclosingScrollView else { return false }
            return content.bounds.width - scroll.convert(scroll.bounds, to: nil).maxX > 200
        }
        /// Soulignement lavande sous un passage, mesuré sur l'image.
        func underlined(_ range: NSRange, in rep: NSBitmapImageRep) -> Bool {
            guard let frame = content.superview else { return false }
            let screen = tv.firstRect(forCharacterRange: NSRange(location: range.location, length: min(range.length, 12)), actualRange: nil)
            let rect = frame.convert(window.convertFromScreen(screen), from: nil)
            let scale = CGFloat(rep.pixelsWide) / frame.bounds.width
            let x0 = Int(rect.minX * scale), x1 = Int(rect.maxX * scale)
            let yTop = Int((frame.bounds.height - rect.minY) * scale) - 2, yBottom = Int((frame.bounds.height - rect.minY + 6) * scale)
            var hits = 0
            for y in max(0, yTop)..<min(rep.pixelsHigh, yBottom) {
                for x in stride(from: max(0, x0), to: min(rep.pixelsWide, x1), by: 2) {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.blueComponent - c.greenComponent > 0.15 { hits += 1 }
                }
            }
            return hits > 10
        }

        // 1. Volet mémorisé ouvert, document sans commentaire : il ne s'affiche pas.
        editor.commentsPanelVisible = true
        await settle()
        check(store.comments.isEmpty, "document de départ sans commentaire")
        check(!editor.commentsPanelShown && !panelOnScreen(), "volet vide jamais ouvert tout seul (même mémorisé ouvert)")
        _ = snapshot("1-sans-commentaire")

        // 2. Deux commentaires : le volet s'ouvre, la pastille compte 2, les passages sont soulignés.
        let text = tv.string as NSString
        let quotes = ["le bon sens ou la raison", "géomètres"]
        var ranges: [NSRange] = []
        for (i, q) in quotes.enumerated() {
            let r = text.range(of: q, options: [], range: NSRange(location: i == 0 ? 0 : NSMaxRange(ranges[0]), length: text.length - (i == 0 ? 0 : NSMaxRange(ranges[0]))))
            guard r.location != NSNotFound else { check(false, "passage « \(q) » introuvable"); continue }
            ranges.append(r)
            tv.setSelectedRange(r)
            tv.onComment?(r)
            store.draftText = "Commentaire de vérification \(i + 1)"
            store.commitDraft()
        }
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.scrollToShow(ranges.first?.location ?? 0)
        await settle(1.0)
        check(store.openCount == 2 && editor.commentsPanelShown && panelOnScreen(), "deux commentaires en cours, volet ouvert")
        if let rep = snapshot("2-deux-commentaires"), let r = ranges.first {
            check(underlined(r, in: rep), "passage commenté souligné dans le texte")
        }

        // 3. Envoi à Claude : un seul prompt, puis archivage.
        var prompt = ""
        editor.sendToClaude { prompt = $0 }
        try? prompt.write(to: folder.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
        await settle(1.0)
        check(prompt.contains("Commentaire de vérification 1") && prompt.contains("Commentaire de vérification 2"), "le prompt contient les deux commentaires")
        check(store.openCount == 0 && store.archivedCount == 2 && store.visibleComments.isEmpty, "après l'envoi : 0 en cours, 2 archivés, volet vidé")
        check(editor.commentsPanelShown && store.lastSentCount == 2, "le volet reste ouvert sur la confirmation")
        if let rep = snapshot("3-envoyes"), let r = ranges.first {
            check(!underlined(r, in: rep), "soulignements retirés du texte après l'envoi")
        }
        let sidecar = (Sidecar.url(.commentaires, for: url, in: root)).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        check(sidecar.contains("\"sent\""), "archive enregistrée dans .ecritoire/commentaires")
        check((try? String(contentsOf: url, encoding: .utf8)) == original, "le fichier .md n'est pas touché")

        // 4. Archives : on les revoit, on en restaure un.
        store.setShowArchive(true)
        await settle()
        check(store.visibleComments.count == 2, "« Archives » montre les 2 commentaires envoyés")
        _ = snapshot("4-archives")
        if let first = store.visibleComments.first { store.restore(first.id) }
        store.setShowArchive(false)
        await settle(1.0)
        check(store.openCount == 1 && store.archivedCount == 1, "restauré : 1 en cours, 1 archivé")
        if let rep = snapshot("5-restaure") {
            check(ranges.contains { underlined($0, in: rep) }, "le commentaire restauré est de nouveau souligné")
        }

        // 5. Bouton bulle / ⌥⌘C : masque puis rouvre, état mémorisé.
        editor.toggleCommentsPanel()
        await settle()
        check(!editor.commentsPanelShown && !panelOnScreen() && !UserDefaults.standard.bool(forKey: "panneauCommentaires"), "⌥⌘C masque le volet (mémorisé)")
        editor.toggleCommentsPanel()
        await settle()
        check(editor.commentsPanelShown && panelOnScreen(), "⌥⌘C le rouvre")

        // 6. Réouverture du document : ouvert s'il reste un commentaire en cours, jamais vide.
        editor.open(nil); await settle(0.4); editor.open(url); await settle()
        check(editor.commentsPanelShown && panelOnScreen(), "document rouvert avec 1 commentaire en cours : volet ouvert")
        if let id = store.activeComments.first?.id { store.toggleResolved(id) }
        editor.open(nil); await settle(0.4); editor.open(url); await settle()
        check(!editor.commentsPanelShown && !panelOnScreen(), "document rouvert sans commentaire en cours : volet fermé")
        _ = snapshot("6-rouvert-sans-commentaire")
        print("commentaires : \(failures) échec(s)")
        NSApp.terminate(nil)
    }
}
