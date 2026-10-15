import AppKit
import SwiftUI
import EcritoireCore

/// Recherche globale (⇧⌘F) : index en mémoire du classeur ou de tous les classeurs, tenu à jour par FSEvents,
/// recherche pendant la frappe en arrière-plan. Rien n'est écrit dans les fichiers.
@MainActor
final class SearchController: ObservableObject {
    enum Scope: String { case classeur, tous }

    @Published var query = "" { didSet { if query != oldValue { schedule() } } }
    @Published var scope = Scope(rawValue: UserDefaults.standard.string(forKey: "porteeRecherche") ?? "") ?? .classeur {
        didSet {
            guard scope != oldValue else { return }
            UserDefaults.standard.set(scope.rawValue, forKey: "porteeRecherche")
            prepareIndex()
            schedule(immediately: true)
        }
    }
    @Published private(set) var results: SearchIndex.Results?
    /// Requête à laquelle correspondent les résultats affichés.
    private(set) var lastQueryAnswered = ""
    @Published private(set) var indexing = false
    /// Occurrences supplémentaires chargées (« afficher les autres ») par document.
    @Published private(set) var expanded: [String: [SearchIndex.Hit]] = [:]
    /// Élément sélectionné au clavier (↑/↓) : identifiant d'occurrence ou de document.
    @Published var selection: String?
    /// Incrémenté pour donner le focus au champ de recherche.
    @Published private(set) var focusToken = 0

    /// Dossier « tous les classeurs » (`ECRITOIRE_CLASSEURS` le remplace, pour les vérifications sur des copies).
    static let allBindersRoot = ProcessInfo.processInfo.environment["ECRITOIRE_CLASSEURS"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Classeurs")

    private var binderRoot: URL?
    private var indexes: [URL: SearchIndex] = [:]
    private var allWatcher: FileWatcher?
    private var work: DispatchWorkItem?
    private var generation = 0
    private let queue = DispatchQueue(label: "ecritoire.recherche", qos: .userInitiated)

    var activeRoot: URL? { scope == .tous ? Self.allBindersRoot : binderRoot }
    var activeIndex: SearchIndex? { activeRoot.flatMap { indexes[$0.standardizedFileURL.resolvingSymlinksInPath()] } }

    func focusField() { focusToken += 1 }

    /// Nouveau classeur ouvert : l'index précédent du classeur est oublié.
    func setBinder(_ url: URL?) {
        if let old = binderRoot?.standardizedFileURL.resolvingSymlinksInPath(), old != Self.allBindersRoot.standardizedFileURL.resolvingSymlinksInPath() {
            indexes[old] = nil
        }
        binderRoot = url
        expanded = [:]
        results = nil
        if active { prepareIndex(); schedule(immediately: true) }
    }

    /// Le mode Recherche est affiché : l'index est construit à la première utilisation.
    var active = false {
        didSet { if active && !oldValue { prepareIndex(); schedule(immediately: true) } }
    }

    private func prepareIndex() {
        guard let root = activeRoot?.standardizedFileURL.resolvingSymlinksInPath(), indexes[root] == nil else { return }
        let index = SearchIndex(root: root)
        indexes[root] = index
        indexing = true
        queue.async { [weak self] in
            index.build()
            DispatchQueue.main.async {
                guard let self else { return }
                self.indexing = false
                self.schedule(immediately: true)
            }
        }
        if scope == .tous {
            // Le classeur ouvert est surveillé par l'espace de travail ; les autres classeurs, ici.
            allWatcher = FileWatcher(root: root) { [weak self] paths in
                MainActor.assumeIsolated { self?.diskChanged(paths) }
            }
        }
    }

    /// Fichiers modifiés sur le disque (FSEvents) : index mis à jour, recherche relancée.
    func diskChanged(_ paths: [String]) {
        let markdown = paths.filter { $0.lowercased().hasSuffix(".md") || !$0.contains(".") }
        guard !markdown.isEmpty else { return }
        let targets = indexes.values.filter { index in markdown.contains { $0.hasPrefix(index.root.path + "/") } }
        guard !targets.isEmpty else { return }
        queue.async { [weak self] in
            for index in targets where index.isReady {
                index.update(paths: markdown.filter { $0.hasPrefix(index.root.path + "/") })
            }
            DispatchQueue.main.async { self?.schedule(immediately: true) }
        }
    }

    /// Recherche pendant la frappe, après une courte pause (150 ms) ; une recherche plus récente annule la précédente.
    func schedule(immediately: Bool = false) {
        work?.cancel()
        generation += 1
        let current = generation
        let parsed = SearchQuery(query)
        let parsedText = query
        guard !parsed.isEmpty else {
            results = nil
            expanded = [:]
            selection = nil
            return
        }
        guard let index = activeIndex, index.isReady else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let box = GenerationBox(self.generation)
            self.queue.async {
                let found = index.search(parsed, cancelled: { box.value != current })
                DispatchQueue.main.async { [weak self] in
                    guard let self, let found, current == self.generation else { return }
                    self.results = found
                    self.lastQueryAnswered = parsedText
                    self.expanded = [:]
                    self.selection = found.documents.first.map { $0.hits.first?.id ?? $0.id }
                }
            }
            self.cancelBox = box
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.15), execute: item)
    }

    private var cancelBox: GenerationBox? {
        didSet { oldValue?.value = -1 }
    }

    /// Toutes les occurrences d'un document (au-delà des 8 premières).
    func expand(_ doc: SearchIndex.DocumentResult) {
        guard let index = activeIndex else { return }
        let parsed = SearchQuery(query)
        queue.async { [weak self] in
            let hits = index.moreHits(in: doc.url, query: parsed)
            DispatchQueue.main.async { self?.expanded[doc.id] = hits }
        }
    }

    func hits(of doc: SearchIndex.DocumentResult) -> [SearchIndex.Hit] { expanded[doc.id] ?? doc.hits }

    /// Liste à plat (document, occurrence) pour la navigation au clavier.
    var flatItems: [(doc: SearchIndex.DocumentResult, hit: SearchIndex.Hit?)] {
        guard let results else { return [] }
        var out: [(SearchIndex.DocumentResult, SearchIndex.Hit?)] = []
        for doc in results.documents {
            let hits = self.hits(of: doc)
            if hits.isEmpty { out.append((doc, nil)) } else { out += hits.map { (doc, $0) } }
        }
        return out
    }

    func moveSelection(_ delta: Int) {
        let items = flatItems
        guard !items.isEmpty else { return }
        let ids = items.map { $0.hit?.id ?? $0.doc.id }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
        selection = ids[min(max(current + delta, 0), ids.count - 1)]
    }

    var selectedItem: (doc: SearchIndex.DocumentResult, hit: SearchIndex.Hit?)? {
        flatItems.first { ($0.hit?.id ?? $0.doc.id) == selection }
    }
}

/// Numéro de génération partagé avec la file de recherche (annulation).
final class GenerationBox: @unchecked Sendable {
    var value: Int
    init(_ value: Int) { self.value = value }
}

extension Workspace {
    /// Ouvre le document d'un résultat (en changeant de classeur si besoin), défile et fait clignoter le passage.
    func openSearchResult(_ url: URL, range: NSRange?) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let rootURL, !path.hasPrefix(rootURL.path + "/") {
            // Résultat d'un autre classeur : le classeur est le premier dossier sous « Classeurs ».
            let all = SearchController.allBindersRoot.standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix(all + "/"), let first = path.dropFirst(all.count + 1).split(separator: "/").first {
                open(binder: URL(fileURLWithPath: all).appendingPathComponent(String(first)))
            }
        }
        if editor.url.map({ $0.standardizedFileURL.resolvingSymlinksInPath().path }) != path {
            selectedURL = url
        }
        if let range {
            editor.jumpRequest = EditorModel.JumpRequest(location: range.location, length: range.length, flash: true)
        }
    }
}
