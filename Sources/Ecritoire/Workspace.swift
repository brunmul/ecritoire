import AppKit
import SwiftUI
import UniformTypeIdentifiers
import EcritoireCore
import ScrivenerImport

/// Le classeur ouvert : arbre, sélection, opérations de fichiers et surveillance du disque.
@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var root: BinderNode?
    /// Incrémenté à chaque changement de structure de l'arbre (pour recharger la barre latérale).
    @Published private(set) var treeVersion = 0
    @Published var selectedURL: URL? {
        didSet { selectionChanged() }
    }
    /// Élément dont la barre latérale doit lancer le renommage (après une création).
    @Published var renameRequest: URL?
    @Published var errorMessage: String?
    /// Message affiché pendant un import Scrivener.
    @Published var importProgress: String?
    @Published var focusMode = false
    @Published var showInspector = false
    // État d'interface gardé ici : les outils en ligne de commande n'ont pas le plugin de macro de @State.
    @Published var columns = NavigationSplitViewVisibility.all
    var inspectorBeforeFocus = false

    let editor = EditorModel()
    /// Recherche globale (volet de gauche en mode « Recherche »).
    let search = SearchController()
    enum SidebarMode { case classeur, recherche }
    @Published var sidebarMode = SidebarMode.classeur {
        didSet { search.active = sidebarMode == .recherche }
    }

    /// ⇧⌘F : volet de gauche en mode Recherche, champ prêt à la frappe.
    func showSearch() {
        if columns != .all { columns = .all }
        sidebarMode = .recherche
        search.focusField()
    }
    private var watcher: FileWatcher?
    private var treeReloadWork: DispatchWorkItem?
    private var suppressSelectionOpen = false

    private static let lastBinderKey = "dernierClasseur"
    private static func lastDocumentKey(_ root: URL) -> String { "dernierDocument:" + root.path }

    /// Classeur de la fenêtre principale (pour les scénarios de vérification lancés par l'AppDelegate).
    static weak var current: Workspace?

    init() {
        Self.current = self
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--classeur"), i + 1 < args.count {
            open(binder: URL(fileURLWithPath: args[i + 1]))
            if let j = args.firstIndex(of: "--document"), j + 1 < args.count {
                selectedURL = URL(fileURLWithPath: args[j + 1])
            }

        } else if let path = UserDefaults.standard.string(forKey: Self.lastBinderKey),
                  Binder.isDirectory(URL(fileURLWithPath: path)) {
            open(binder: URL(fileURLWithPath: path))
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.editor.flush() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.editor.flush() }
        }
    }

    var binderName: String { rootURL?.lastPathComponent ?? "Écritoire" }

    // MARK: Classeur

    func chooseBinder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Ouvrir"
        panel.message = "Choisissez le dossier qui sert de classeur (il peut être vide)."
        if panel.runModal() == .OK, let url = panel.url {
            open(binder: url)
        }
    }

    func open(binder url: URL) {
        editor.flush()
        editor.open(nil)
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        rootURL = url
        editor.binderRoot = url
        search.setBinder(url)
        UserDefaults.standard.set(url.path, forKey: Self.lastBinderKey)
        reloadTree(force: true)
        watcher = FileWatcher(root: url) { [weak self] paths in
            MainActor.assumeIsolated { self?.diskChanged(paths) }
        }
        if let last = UserDefaults.standard.string(forKey: Self.lastDocumentKey(url)),
           FileManager.default.fileExists(atPath: last) {
            selectedURL = URL(fileURLWithPath: last)
        } else {
            selectedURL = root?.allDescendants.first(where: { !$0.isFolder })?.url
        }
    }

    func reloadTree(force: Bool = false) {
        guard let rootURL else { return }
        let fresh = Binder.loadTree(at: rootURL)
        if force || root.map(signature) != signature(fresh) {
            root = fresh
            treeVersion += 1
        }
    }

    private func signature(_ node: BinderNode) -> [String] {
        node.allDescendants.map { ($0.isFolder ? "d:" : "f:") + $0.url.path }
    }

    private func diskChanged(_ paths: [String]) {
        search.diskChanged(paths)
        if let current = editor.url {
            let resolved = current.resolvingSymlinksInPath().path
            if paths.contains(where: { $0 == resolved || $0 == current.path }) {
                editor.fileDidChangeOnDisk()
            }
        }
        treeReloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reloadTree()
            if let current = self.editor.url, !FileManager.default.fileExists(atPath: current.path) {
                self.editor.open(nil)
            }
        }
        treeReloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: Sélection

    var selectedNode: BinderNode? { selectedURL.flatMap { root?.find($0) } }

    private func selectionChanged() {
        guard !suppressSelectionOpen, let url = selectedURL, let rootURL else { return }
        if !Binder.isDirectory(url) {
            editor.open(url)
            UserDefaults.standard.set(url.path, forKey: Self.lastDocumentKey(rootURL))
        }
    }

    private func selectWithoutOpening(_ url: URL?) {
        suppressSelectionOpen = true
        selectedURL = url
        suppressSelectionOpen = false
    }

    // MARK: Export

    /// Ce qu'on exporte : l'élément sélectionné dans le classeur (document ou dossier), à défaut le document ouvert.
    var exportTarget: URL? { selectedURL ?? editor.url }

    /// Fichier → Exporter… : Markdown ou PDF, dans un fichier choisi hors du classeur (les sources ne changent jamais).
    func exportSelection() {
        guard let target = exportTarget else { return }
        editor.flush()
        let sections = Export.sections(for: target, root: rootURL)
        guard let first = sections.first else {
            errorMessage = "Rien à exporter dans « \(target.lastPathComponent) »."
            return
        }
        let chooser = ExportFormatChooser()
        let panel = NSSavePanel()
        panel.title = "Exporter « \(first.title) »"
        panel.prompt = "Exporter"
        panel.nameFieldStringValue = first.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        chooser.attach(to: panel)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // Jamais dans le classeur : un .md y deviendrait un document, une image copiée pourrait en remplacer une.
        if let rootURL, destination.standardizedFileURL.path.hasPrefix(rootURL.standardizedFileURL.path + "/") {
            errorMessage = "Choisissez un emplacement hors du classeur : l'export ne doit pas se mêler à vos documents."
            return
        }
        do {
            switch chooser.format {
            case .markdown: try Export.writeMarkdown(sections, to: destination)
            case .pdf: try PDFExport.write(sections, title: first.title, to: destination)
            }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            errorMessage = "Export impossible : \(error.localizedDescription)"
        }
    }

    // MARK: Opérations

    /// Où créer un nouvel élément : dans le dossier sélectionné, ou juste après le document sélectionné.
    private func insertionPoint(relativeTo node: BinderNode?) -> (URL, Int?)? {
        guard let root else { return nil }
        guard let node, node !== root else { return (root.url, nil) }
        if node.isFolder { return (node.url, nil) }
        let parent = node.parent ?? root
        let index = parent.children.firstIndex(of: node).map { $0 + 1 }
        return (parent.url, index)
    }

    func newDocument(relativeTo node: BinderNode? = nil) {
        guard let (folder, index) = insertionPoint(relativeTo: node ?? selectedNode) else { return }
        perform {
            let url = try Binder.createDocument(in: folder, at: index)
            reloadTree(force: true)
            selectedURL = url
            renameRequest = url
        }
    }

    func newFolder(relativeTo node: BinderNode? = nil) {
        guard let (folder, index) = insertionPoint(relativeTo: node ?? selectedNode) else { return }
        perform {
            let url = try Binder.createFolder(in: folder, at: index)
            reloadTree(force: true)
            selectWithoutOpening(url)
            renameRequest = url
        }
    }

    func rename(_ url: URL, to name: String) {
        perform {
            editor.flush()
            let newURL = try Binder.rename(url, to: name)
            if let rootURL { Sidecar.relocate(from: url, to: newURL, in: rootURL) }
            guard newURL != url else { return }
            editor.relocate(from: url, to: newURL)
            reloadTree(force: true)
            selectWithoutOpening(newURL)
        }
    }

    func move(_ url: URL, into folder: URL, at index: Int?) {
        perform {
            editor.flush()
            let newURL = try Binder.move(url, into: folder, at: index)
            if let rootURL { Sidecar.relocate(from: url, to: newURL, in: rootURL) }
            editor.relocate(from: url, to: newURL)
            reloadTree(force: true)
            selectWithoutOpening(newURL)
        }
    }

    func trash(_ url: URL) {
        perform {
            if let current = editor.url, current.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path) {
                editor.open(nil)
            }
            try Binder.trash(url)
            reloadTree(force: true)
            selectWithoutOpening(nil)
        }
    }

    // MARK: Import Scrivener

    /// Choisit un projet .scriv, le convertit dans ~/Documents/Classeurs (l'original n'est pas modifié), puis l'ouvre.
    func importScrivener() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Importer"
        panel.message = "Choisissez un projet Scrivener (.scriv). Il sera converti en classeur dans Documents/Classeurs, sans être modifié."
        guard panel.runModal() == .OK, let project = panel.url else { return }
        guard project.pathExtension.lowercased() == "scriv" else {
            errorMessage = "Choisissez un fichier de projet Scrivener (.scriv)."
            return
        }
        let destination = ScrivenerImporter.defaultDestination()
        importProgress = "Import de « \(project.deletingPathExtension().lastPathComponent) »…"
        Task.detached { [weak self] in
            do {
                let importer = try ScrivenerImporter(project: project, destinationFolder: destination)
                importer.progress = { count in
                    guard count % 50 == 0 else { return }
                    Task { @MainActor in self?.importProgress = "Import en cours… \(count) documents" }
                }
                let report = try importer.run()
                await MainActor.run {
                    self?.importProgress = nil
                    self?.open(binder: report.destination)
                    if !report.warnings.isEmpty {
                        self?.errorMessage = "Import terminé avec \(report.warnings.count) avertissement(s) :\n" +
                            report.warnings.prefix(10).joined(separator: "\n")
                    }
                }
            } catch {
                await MainActor.run {
                    self?.importProgress = nil
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func setIcon(_ icon: String?, for url: URL) {
        perform {
            try Binder.setIcon(icon, for: url)
            reloadTree(force: true)
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

/// Choix du format dans le panneau d'enregistrement de l'export (dernier choix retenu).
@MainActor
final class ExportFormatChooser: NSObject {
    enum Format: String { case pdf, markdown }
    private static let key = "formatExport"
    private(set) var format = Format(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .pdf
    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    func attach(to panel: NSSavePanel) {
        self.panel = panel
        popup.addItems(withTitles: ["PDF", "Markdown"])
        popup.selectItem(at: format == .pdf ? 0 : 1)
        popup.target = self
        popup.action = #selector(changed)
        let label = NSTextField(labelWithString: "Format :")
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        panel.accessoryView = row
        apply()
    }

    @objc private func changed() {
        format = popup.indexOfSelectedItem == 0 ? .pdf : .markdown
        UserDefaults.standard.set(format.rawValue, forKey: Self.key)
        apply()
    }

    private func apply() {
        guard let panel else { return }
        let type: UTType = format == .pdf ? .pdf : (UTType(filenameExtension: "md") ?? .plainText)
        panel.allowedContentTypes = [type]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + (format == .pdf ? ".pdf" : ".md")
    }
}
