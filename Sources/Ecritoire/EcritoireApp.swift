import AppKit
import SwiftUI
import EcritoireCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Vérification : `--exporter <document ou dossier> <fichier.pdf|.md> [--racine <classeur>]` exporte puis quitte,
    /// avant l'ouverture de toute fenêtre (ne prend jamais le premier plan).
    func applicationWillFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--exporter"), i + 2 < args.count else { return }
        let source = URL(fileURLWithPath: args[i + 1]), destination = URL(fileURLWithPath: args[i + 2])
        let root = args.firstIndex(of: "--racine").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        MainActor.assumeIsolated {
            let sections = Export.sections(for: source, root: root)
            do {
                if destination.pathExtension.lowercased() == "pdf" {
                    try PDFExport.write(sections, title: sections.first?.title ?? "", to: destination)
                    print("export : \(PDFExport.lastPageCount) page(s), \(sections.count) section(s)")
                } else {
                    let files = try Export.writeMarkdown(sections, to: destination)
                    print("export : \(files.count) fichier(s), \(sections.count) section(s)")
                }
            } catch {
                print("export : erreur \(error.localizedDescription)")
                exit(1)
            }
        }
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nécessaire quand l'exécutable est lancé directement (swift run), hors d'un paquet .app.
        NSApp.setActivationPolicy(.regular)
        // Les scénarios de vérification tournent en arrière-plan : ne pas voler le clavier à l'utilisateur.
        let probes = ["--perf", "--demo", "--revue", "--sommaire", "--capture", "--curseur", "--decalage", "--pointeur", "--parcours", "--poeme-captures", "--poeme-edition", "--commentaires-circuit", "--recherche-captures"]
        if !CommandLine.arguments.contains(where: probes.contains) {
            NSApp.activate(ignoringOtherApps: true)
        }
        // Vérification automatique : `--capture fichier.png` enregistre une image de la fenêtre puis quitte.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--perf"), i + 1 < args.count, let n = Int(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { PerfProbe.run(keystrokes: n) }
        }
        if let i = args.firstIndex(of: "--revue"), i + 1 < args.count {
            let output = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if let workspace = Workspace.current { Task { @MainActor in await ReviewProbe.run(output: output, workspace: workspace) } }
                else { print("revue: pas de classeur"); exit(1) }
            }
        }
        if let i = args.firstIndex(of: "--sommaire"), i + 1 < args.count {
            let output = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if let workspace = Workspace.current { Task { @MainActor in await OutlineProbe.run(output: output, workspace: workspace) } }
            }
        }
        if let i = args.firstIndex(of: "--parcours"), i + 1 < args.count {
            let folder = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { @MainActor in await JourneyProbe.run(folder: folder) } }
        }
        if let i = args.firstIndex(of: "--poeme-captures"), i + 1 < args.count {
            let folder = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { @MainActor in await PoemProbe.captures(folder: folder) } }
        }
        if let i = args.firstIndex(of: "--commentaires-circuit"), i + 1 < args.count {
            let folder = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { @MainActor in await CommentsProbe.run(folder: folder) } }
        }
        if let i = args.firstIndex(of: "--recherche-captures"), i + 1 < args.count {
            let folder = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { @MainActor in await SearchProbe.run(folder: folder) } }
        }
        if args.contains("--poeme-edition") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { @MainActor in await PoemProbe.editing() } }
        }
        if args.contains("--decalage") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { @MainActor in await OffsetProbe.run() } }
        }
        if let i = args.firstIndex(of: "--curseur"), i + 1 < args.count {
            let folder = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { @MainActor in await CaretProbe.run(folder: folder) } }
        }
        if let i = args.firstIndex(of: "--demo"), i + 1 < args.count {
            let output = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { DemoProbe.run(output: output) }
        }
        if let i = args.firstIndex(of: "--capture"), i + 1 < args.count {
            let output = URL(fileURLWithPath: args[i + 1])
            let scroll = args.firstIndex(of: "--defiler").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
            if let k = args.firstIndex(of: "--chercher"), k + 1 < args.count {
                let needle = args[k + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    func find(_ v: NSView) -> WritingTextView? { (v as? WritingTextView) ?? v.subviews.lazy.compactMap(find).first }
                    if let content = NSApp.windows.first(where: { $0.isVisible })?.contentView, let tv = find(content) {
                        let r = (tv.string as NSString).range(of: needle)
                        if r.location != NSNotFound { tv.scrollToShow(r.location) }
                    }
                }
            }
            if args.contains("--survol") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                    func find(_ v: NSView) -> WritingTextView? { (v as? WritingTextView) ?? v.subviews.lazy.compactMap(find).first }
                    if let content = NSApp.windows.first(where: { $0.isVisible })?.contentView, let tv = find(content) {
                        let visible = tv.visibleRect
                        tv.updateHover(at: NSPoint(x: tv.textContainerOrigin.x + 100, y: visible.minY + visible.height * 0.75))
                        if let rep = NSBitmapImageRep(data: { let i = WritingTextView.elegantIBeam.image
                               let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(i.size.width * 4), pixelsHigh: Int(i.size.height * 4), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                               r.size = i.size
                               NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r)
                               NSColor(white: 0.97, alpha: 1).setFill(); NSRect(origin: .zero, size: i.size).fill()
                               i.draw(in: NSRect(origin: .zero, size: i.size)); NSGraphicsContext.restoreGraphicsState()
                               return r.tiffRepresentation! }()),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: output.deletingLastPathComponent().appendingPathComponent("pointeur-I.png"))
                        }
                    }
                }
            }
            let headingIndex = args.firstIndex(of: "--titre").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
            if let headingIndex {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if let editor = Workspace.current?.editor, editor.live.headings.indices.contains(headingIndex) {
                        editor.jump(to: editor.live.headings[headingIndex])
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let scroll, let content = NSApp.windows.first(where: { $0.isVisible })?.contentView {
                    func find(_ v: NSView) -> NSScrollView? {
                        if let s = v as? NSScrollView, s.documentView is NSTextView { return s }
                        return v.subviews.lazy.compactMap(find).first
                    }
                    if let scrollView = find(content) {
                        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scroll))
                        scrollView.reflectScrolledClipView(scrollView.contentView)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: output)
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct EcritoireApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace = Workspace()
    @AppStorage("machineAEcrire") private var typewriterAlways = false
    @AppStorage("zoom") private var zoom = 1.0
    @AppStorage("sommaire") private var showOutline = true
    @AppStorage("selectionAimantee") private var magneticSelection = true
    @AppStorage("defilementAimante") private var magneticScroll = true

    var body: some Scene {
        Window("Écritoire", id: "principal") {
            ContentView(editor: workspace.editor)
                .environmentObject(workspace)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nouveau document") { workspace.newDocument() }
                    .keyboardShortcut("n")
                    .disabled(workspace.rootURL == nil)
                Button("Nouveau dossier") { workspace.newFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(workspace.rootURL == nil)
                Divider()
                Button("Ouvrir un classeur…") { workspace.chooseBinder() }
                    .keyboardShortcut("o")
                Button("Importer un projet Scrivener…") { workspace.importScrivener() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Exporter…") { workspace.exportSelection() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(workspace.exportTarget == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Enregistrer") { workspace.editor.flush() }
                    .keyboardShortcut("s")
            }
            CommandMenu("Format") {
                let run: (EditorCommand) -> Void = { workspace.editor.commandTarget?.perform($0) }
                Button("Gras") { run(.bold) }.keyboardShortcut("b")
                Button("Italique") { run(.italic) }.keyboardShortcut("i")
                Button("Surligner en jaune") { run(.highlight(.jaune)) }.keyboardShortcut("h", modifiers: [.command, .shift])
                Menu("Surligner") {
                    ForEach(HighlightColor.allCases) { color in
                        Button(color.rawValue.capitalized) { run(.highlight(color)) }
                    }
                    Divider()
                    Button("Retirer le surlignage") { run(.eraseHighlight) }
                }
                Button("Lien interne [[…]]") { run(.wikiLink) }.keyboardShortcut("k")
                Divider()
                Button("Corps de texte") { run(.block(.corps)) }.keyboardShortcut("0", modifiers: [.command, .option])
                Button("Titre 1") { run(.block(.titre1)) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Titre 2") { run(.block(.titre2)) }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Titre 3") { run(.block(.titre3)) }.keyboardShortcut("3", modifiers: [.command, .option])
                Button("Intro") { run(.block(.intro)) }.keyboardShortcut("4", modifiers: [.command, .option])
                Button("Citation") { run(.block(.citation)) }.keyboardShortcut("5", modifiers: [.command, .option])
                Button("Liste") { run(.block(.liste)) }.keyboardShortcut("6", modifiers: [.command, .option])
                Divider()
                Toggle("Sélection aimantée (mot, paragraphe)", isOn: $magneticSelection)
            }
            CommandMenu("Révision") {
                let editor = workspace.editor
                Button("Commenter la sélection") { editor.commandTarget?.perform(.comment) }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Button("Afficher ou masquer les commentaires") { editor.toggleCommentsPanel() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Divider()
                Button("Envoyer les commentaires à Claude (copier le prompt)") { editor.copyClaudePrompt() }
                    .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                Button("Enregistrer le prompt pour Claude…") { editor.saveClaudePrompt() }
                Divider()
                Button("Créer un instantané (point de comparaison)") { editor.takeSnapshot() }
                Button("Voir les modifications") { editor.enterReview() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Modification précédente") { if let r = editor.review { editor.selectChange(max(0, r.current - 1)) } }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Modification suivante") { if let r = editor.review { editor.selectChange(min(r.changes.count - 1, r.current + 1)) } }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Accepter la modification") { editor.acceptCurrentChange() }
                    .keyboardShortcut("y", modifiers: [.command, .option])
                Button("Refuser la modification") { editor.rejectCurrentChange() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Terminer la relecture") { editor.exitReview() }
            }
            CommandGroup(after: .sidebar) {
                Button("Rechercher dans les titres et le texte") { workspace.showSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(workspace.rootURL == nil)
                Toggle("Mode focus", isOn: $workspace.focusMode)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(workspace.rootURL == nil)
                Toggle("Défilement machine à écrire", isOn: $typewriterAlways)
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Toggle("Défilement aimanté aux paragraphes", isOn: $magneticScroll)
                Toggle("Inspecteur", isOn: $workspace.showInspector)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Toggle("Sommaire", isOn: $showOutline)
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button("Zoomer") { zoom = min(2.0, ((zoom + 0.1) * 10).rounded() / 10) }
                    .keyboardShortcut("+")
                Button("Dézoomer") { zoom = max(0.5, ((zoom - 0.1) * 10).rounded() / 10) }
                    .keyboardShortcut("-")
                Button("Taille réelle (100 %)") { zoom = 1 }
                    .keyboardShortcut("0")
                Divider()
            }
        }
    }
}
