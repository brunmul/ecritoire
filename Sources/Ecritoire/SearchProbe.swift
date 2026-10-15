import AppKit
import EcritoireCore

/// `--recherche-captures dossier` : recherche globale dans l'application, sans l'activer.
/// Temps de réponse pendant la frappe, capture de la liste, saut dans le texte (sélection mesurée sur l'image).
/// À lancer sur une copie du classeur d'exemple, avec `ECRITOIRE_CLASSEURS` = le dossier qui contient cette copie.
@MainActor
enum SearchProbe {
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
              let workspace = Workspace.current else { print("recherche: fenêtre introuvable"); exit(1) }
        let search = workspace.search
        func capture(_ name: String) -> NSBitmapImageRep? {
            guard let frame = content.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
            return rep
        }
        func waitResults(_ timeout: Double = 5) async -> Double {
            let t0 = CFAbsoluteTimeGetCurrent()
            let before = search.results.map { ObjectIdentifier($0.documents as AnyObject) }
            _ = before
            while CFAbsoluteTimeGetCurrent() - t0 < timeout {
                try? await Task.sleep(for: .milliseconds(5))
                if let r = search.results, !search.indexing, r.documents.first != nil || r.totalHits == 0, search.lastQueryAnswered == search.query { break }
            }
            return (CFAbsoluteTimeGetCurrent() - t0) * 1000
        }

        search.scope = .classeur
        workspace.showSearch()
        let t0 = CFAbsoluteTimeGetCurrent()
        while (search.indexing || search.activeIndex?.isReady != true) && CFAbsoluteTimeGetCurrent() - t0 < 30 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let index = search.activeIndex
        print(String(format: "index du classeur : %d documents, %.1f M caractères, prêt en %.0f ms", index?.documentCount ?? 0,
                     Double(index?.characterCount ?? 0) / 1e6, (CFAbsoluteTimeGetCurrent() - t0) * 1000))

        // Frappe lettre par lettre (une touche toutes les 90 ms) : temps entre la dernière touche et l'affichage.
        var engine: [Double] = []
        for word in ["méthode", "bon sens", "l'esprit"] {
            var typed = ""
            for ch in word {
                typed.append(ch)
                search.query = typed
                try? await Task.sleep(for: .milliseconds(90))
            }
            let wait = await waitResults()
            let ms = search.results?.milliseconds ?? -1
            engine.append(ms)
            print(String(format: "« %@ » : recherche %.1f ms (affichage %.0f ms après la dernière touche, pause de 150 ms comprise) — %d documents, %d occurrences",
                         word, ms, wait + 90, search.results?.documents.count ?? 0, search.results?.totalHits ?? 0))
        }
        check((engine.max() ?? 999) < 100, String(format: "moins de 100 ms par recherche (max %.1f ms)", engine.max() ?? -1))

        // Liste de résultats pour une requête de démonstration.
        search.query = "\"bon sens\""
        _ = await waitResults()
        try? await Task.sleep(for: .milliseconds(400))
        _ = capture("recherche-liste")
        let first = search.results?.documents.first { !$0.hits.isEmpty }
        check(first != nil, "résultats avec contexte pour « bon sens »")
        if let hit = first?.hits.first {
            check(hit.match.lowercased().contains("bon") && hit.match.lowercased().contains("sens"), "terme surligné : « \(hit.match) »")
            print("  contexte : …\(hit.before.suffix(60))[\(hit.match)]\(hit.after.prefix(60))…  (\(hit.heading ?? "sans intertitre"))")
        }

        // Clavier : ↓ deux fois puis Entrée → ouvre l'occurrence sélectionnée.
        search.moveSelection(1)
        search.moveSelection(1)
        guard let item = search.selectedItem, let hit = item.hit else { check(false, "sélection au clavier"); finish(); return }
        workspace.openSearchResult(item.doc.url, range: hit.range)
        try? await Task.sleep(for: .seconds(1.5))
        guard let tv = find(content, WritingTextView.self) else { check(false, "éditeur"); finish(); return }
        tv.forceCaretForCapture = true
        check(workspace.editor.url?.standardizedFileURL.path == item.doc.url.standardizedFileURL.path, "document ouvert : \(item.doc.title)")
        check(tv.selectedRange() == hit.range, "passage sélectionné \(tv.selectedRange()) = \(hit.range)")
        let selected = (tv.string as NSString).substring(with: tv.selectedRange())
        check(SearchFold.query(selected) == SearchFold.query(hit.match.replacingOccurrences(of: "*", with: "")), "texte sélectionné « \(selected) »")
        if let rep = capture("recherche-saut") {
            // Le passage est visible et surligné (jaune de sélection) sur l'image.
            let screen = tv.firstRect(forCharacterRange: NSRange(location: hit.range.location, length: min(hit.range.length, 10)), actualRange: nil)
            let frame = content.superview!
            let rect = frame.convert(window.convertFromScreen(screen), from: nil)
            let scale = CGFloat(rep.pixelsWide) / frame.bounds.width
            var yellow = 0
            for y in Int((frame.bounds.height - rect.maxY) * scale)..<Int((frame.bounds.height - rect.minY) * scale) {
                for x in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: 2) {
                    // Fond de sélection : jaune (fenêtre active) ou gris (fenêtre en arrière-plan, comme pendant ce test).
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                        let gray = abs(c.redComponent - c.blueComponent) < 0.03 && c.redComponent > 0.78 && c.redComponent < 0.9
                        let yellowish = c.redComponent > 0.9 && c.greenComponent > 0.8 && c.blueComponent < 0.75
                        if gray || yellowish { yellow += 1 }
                    }
                }
            }
            let visible = tv.visibleRect.intersects(tv.convert(window.convertFromScreen(screen), from: nil))
            check(visible && yellow > 20, "passage visible et sélectionné à l'écran (\(yellow) points de sélection)")
        }

        // Tous les classeurs : le poème cité en « v. n ».
        search.scope = .tous
        search.query = "wasserfall"
        _ = await waitResults(30)
        let poemHit = search.results?.documents.first { $0.relativePath.hasSuffix("Aube.md") }?.hits.first
        check(poemHit?.verse == "v. 4", "poème trouvé dans « Tous les classeurs », cité « \(poemHit?.verse ?? "-") »")
        try? await Task.sleep(for: .milliseconds(300))
        _ = capture("recherche-tous")
        search.scope = .classeur
        finish()
    }

    private static func finish() {
        print("recherche : \(failures) échec(s)")
        NSApp.terminate(nil)
    }
}
