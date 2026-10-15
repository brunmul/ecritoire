import Foundation
import EcritoireCore

/// État du document ouvert : métadonnées, corps, sauvegarde automatique et rechargement depuis le disque.
@MainActor
final class EditorModel: ObservableObject {
    enum SaveState: Equatable {
        case saved, modified, failed(String)
    }

    @Published private(set) var url: URL?
    @Published var title = "" { didSet { metadataEdited(oldValue != title) } }
    @Published var synopsis = "" { didSet { metadataEdited(oldValue != synopsis) } }
    @Published var status = DocumentStatus.brouillon.rawValue { didSet { metadataEdited(oldValue != status) } }
    @Published var publish = false { didSet { metadataEdited(oldValue != publish) } }
    /// État qui change à chaque frappe ou mouvement du curseur, observé seulement par les petites vues
    /// qui l'affichent (barre d'état, sommaire, barre d'édition) — pas par toute la fenêtre.
    let live = LiveStats()
    /// Cible des commandes de mise en forme (la vue texte).
    weak var commandTarget: EditorCommandTarget?

    // MARK: Sommaire
    struct Heading: Identifiable, Equatable {
        let id: Int        // position (UTF-16) du début de la ligne
        let level: Int
        let title: String
    }
    struct JumpRequest: Equatable {
        let id = UUID()
        let location: Int
        /// Passage à sélectionner et faire clignoter (résultat de recherche).
        var length = 0
        var flash = false
    }
    @Published var jumpRequest: JumpRequest?
    /// Défilement direct (navigation par les barres du sommaire), sans passer par SwiftUI.
    var scrollHandler: ((Int, Bool) -> Void)?
    private var statsWork: DispatchWorkItem?
    private var statsGeneration = 0
    @Published private(set) var saveState = SaveState.saved
    /// Le fichier a changé sur le disque alors que des modifications locales n'étaient pas encore enregistrées.
    @Published private(set) var externalConflict = false
    /// Incrémenté quand le corps doit être (re)chargé dans la vue texte.
    @Published private(set) var reloadToken = 0

    private(set) var body = ""
    private var extraLines: [String] = []
    /// Le fichier avait un en-tête YAML : sinon on n'en ajoute pas (les poèmes sont écrits tels quels).
    private var hasFrontmatter = true

    // MARK: Poème
    /// Affichage « poème » (colonne étroite, versets numérotés en marge), choisi par document.
    @Published private(set) var poemDisplay = false
    /// Le texte suit le format des versets numérotés `[n]` : renumérotation et références « v. n ».
    @Published private(set) var poemNumbering = false

    func setPoemDisplay(_ on: Bool) {
        guard on != poemDisplay else { return }
        poemDisplay = on
        if let url, let root = binderRoot { try? Sidecar.setDisplay(on ? .poeme : .prose, for: url, in: root) }
        scheduleStats()
    }

    /// Affichage par défaut : celui choisi pour ce document, sinon poème dans un classeur « Poèmes » ou pour un texte en versets.
    private func defaultPoemDisplay(numbering: Bool) -> Bool {
        if let url, let root = binderRoot, let chosen = Sidecar.display(for: url, in: root) { return chosen == .poeme }
        let folder = TitleMatch.normalize(binderRoot?.lastPathComponent ?? "")
        return numbering || folder.hasPrefix("poeme")
    }
    var lastWritten = ""

    // MARK: Commentaires et relecture des modifications
    /// Dossier du classeur (pour les fichiers annexes .ecritoire).
    var binderRoot: URL?
    let comments = CommentStore()
    /// Mode « Modifications » : affichage fusionné ancien/nouveau texte (lecture seule).
    @Published var review: ReviewState?
    /// Nombre de modifications depuis l'instantané (bandeau), nil s'il n'y a pas d'instantané.
    @Published var pendingChanges: Int?
    /// Volet des commentaires (à droite) : choix mémorisé de l'utilisateur (bouton bulle, ⌥⌘C).
    @Published var commentsPanelVisible = UserDefaults.standard.bool(forKey: "panneauCommentaires") {
        didSet { UserDefaults.standard.set(commentsPanelVisible, forKey: "panneauCommentaires") }
    }
    /// Volet ouvert explicitement pour ce document (même vide) ; remis à zéro à chaque ouverture de document.
    @Published var commentsPanelForced = false

    /// Le volet ne s'affiche jamais tout seul quand il est vide : il faut des commentaires en cours,
    /// un commentaire en train d'être écrit, ou une demande explicite (bouton, ⌥⌘C, archives).
    var commentsPanelShown: Bool {
        commentsPanelVisible && (comments.openCount > 0 || comments.draftRange != nil || commentsPanelForced)
    }

    func toggleCommentsPanel() {
        if commentsPanelShown {
            commentsPanelVisible = false
            commentsPanelForced = false
        } else {
            revealCommentsPanel()
        }
    }

    func revealCommentsPanel() {
        commentsPanelForced = true
        commentsPanelVisible = true
    }
    var snapshotDate: Date?
    var diffGeneration = 0
    private var isDirty = false
    private var isLoading = false
    private var saveWork: DispatchWorkItem?
    static let autosaveDelay: TimeInterval = 0.8

    // MARK: Ouverture

    func open(_ newURL: URL?) {
        if let url, let newURL, Binder.samePath(url, newURL) { return }
        flush()
        externalConflict = false
        guard let newURL else {
            close()
            return
        }
        url = newURL
        commentsPanelForced = false
        load()
        live.sessionStartCount = live.wordCount
    }

    func close() {
        saveWork?.cancel()
        url = nil
        isLoading = true
        title = ""; synopsis = ""; status = DocumentStatus.brouillon.rawValue; publish = false
        isLoading = false
        body = ""
        extraLines = []
        lastWritten = ""
        isDirty = false
        live.reset()
        poemDisplay = false
        poemNumbering = false
        review = nil
        pendingChanges = nil
        comments.load(document: nil, root: nil, text: "")
        saveState = .saved
        reloadToken += 1
    }

    private func load() {
        guard let url else { return }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            saveState = .failed("Lecture impossible : \(error.localizedDescription)")
            return
        }
        let doc = MarkdownDocument.parse(text, defaultTitle: url.deletingPathExtension().lastPathComponent)
        hasFrontmatter = text.hasPrefix("---\n") || text.hasPrefix("---\r\n")
        isLoading = true
        title = doc.title
        synopsis = doc.synopsis
        status = doc.status
        publish = doc.publish
        isLoading = false
        body = doc.body
        extraLines = doc.extraLines
        lastWritten = text
        isDirty = false
        saveState = .saved
        poemNumbering = Poem.isPoem(body)
        poemDisplay = defaultPoemDisplay(numbering: poemNumbering)
        let stats = Self.computeStats(body, title: displayTitle, poem: poemDisplay && poemNumbering)
        live.apply(stats)
        review = nil
        comments.load(document: url, root: binderRoot, text: body as NSString)
        refreshPendingChanges()
        reloadToken += 1
    }

    /// Le fichier ouvert a été renommé ou déplacé par l'application.
    func relocate(from old: URL, to new: URL) {
        guard let url else { return }
        let oldPath = old.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == oldPath {
            self.url = new
        } else if path.hasPrefix(oldPath + "/") {
            self.url = URL(fileURLWithPath: new.standardizedFileURL.path + path.dropFirst(oldPath.count))
        }
        if let current = self.url { comments.relocate(to: current) }
    }

    // MARK: Modifications

    /// Appelé à chaque frappe : doit rester presque gratuit. Les comptes et le sommaire
    /// sont recalculés en arrière-plan après une courte pause.
    func bodyDidChange(_ text: String) {
        body = text
        scheduleStats()
        markDirty()
    }

    func jump(to heading: Heading) {
        jumpRequest = JumpRequest(location: heading.id)
    }

    struct Stats: Sendable {
        let words: Int
        let characters: Int
        let headings: [Heading]
        /// Début de chaque paragraphe non vide (graduations fines de la règle du sommaire).
        var paragraphs: [Int] = []
        /// Premier titre du texte identique au titre du document : masqué (le titre est affiché hors de la page).
        var titleHeading: Int? = nil
        var isPoem = false
    }

    nonisolated static func computeStats(_ text: String, title: String = "", poem: Bool = false) -> Stats {
        let isPoem = Poem.isPoem(text)
        // Poème : les versets tiennent lieu de titres dans le sommaire (numéro et premiers mots).
        if poem && isPoem {
            let verses = Poem.verses(in: text)
            let headings = verses.map {
                Heading(id: $0.range.location, level: 1, title: "\($0.number)\u{2002}\(Poem.incipit($0.text))")
            }
            var stats = Stats(words: WordCounter.count(text) - verses.filter { $0.marker != nil }.count, characters: (text as NSString).length,
                              headings: headings, paragraphs: [], titleHeading: nil)
            stats.isPoem = true
            return stats
        }
        let duplicate = TitleMatch.duplicatedTitle(in: text, title: title)?.location
        var headings = extractHeadings(text)
        if let duplicate { headings.removeAll { $0.id == duplicate } }
        var paragraphs = paragraphStarts(text)
        if let duplicate { paragraphs.removeAll { $0 == duplicate } }
        var stats = Stats(words: WordCounter.count(text), characters: (text as NSString).length, headings: headings,
                          paragraphs: paragraphs, titleHeading: duplicate)
        stats.isPoem = isPoem
        return stats
    }

    /// Titre affiché au-dessus de la page : le titre de l'en-tête, à défaut le nom du fichier.
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? (url?.deletingPathExtension().lastPathComponent ?? "") : t
    }

    nonisolated static func paragraphStarts(_ text: String) -> [Int] {
        var out: [Int] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            if range.length > 0 && ns.character(at: range.location) != 0x23 { out.append(range.location) } // ni vide ni titre
        }
        return out
    }

    private func scheduleStats() {
        statsWork?.cancel()
        statsGeneration += 1
        let generation = statsGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.body
            let title = self.displayTitle
            let poem = self.poemDisplay
            DispatchQueue.global(qos: .userInitiated).async {
                let stats = EditorModel.computeStats(snapshot, title: title, poem: poem)
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.statsGeneration else { return }
                    if self.poemNumbering != stats.isPoem { self.poemNumbering = stats.isPoem }
                    self.live.apply(stats)
                }
            }
        }
        statsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Titres Markdown (# à ######) hors blocs de code, avec leur position dans le texte.
    nonisolated static func extractHeadings(_ text: String) -> [Heading] {
        var result: [Heading] = []
        var inFence = false
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            guard range.length > 0 else { return }
            let first = ns.character(at: range.location)
            if first == 0x60 || first == 0x7E { // ` ou ~
                let line = ns.substring(with: range)
                if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
                return
            }
            guard !inFence, first == 0x23 else { return } // #
            let line = ns.substring(with: range)
            let level = line.prefix(while: { $0 == "#" }).count
            guard level <= 6, line.dropFirst(level).first == " " || line.dropFirst(level).first == "\t" else { return }
            var title = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
            title = title.replacingOccurrences(of: #"\*\*|__|(?<!\\)\*|\[\[|\]\]|\\"#, with: "", options: .regularExpression)
            if !title.isEmpty { result.append(Heading(id: range.location, level: level, title: title)) }
        }
        return result
    }

    private func metadataEdited(_ changed: Bool) {
        guard changed, !isLoading, url != nil else { return }
        markDirty()
    }

    private func markDirty() {
        isDirty = true
        if saveState != .modified { saveState = .modified }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autosaveDelay, execute: work)
    }

    // MARK: Sauvegarde

    /// Enregistre immédiatement s'il y a des modifications en attente.
    func flush() {
        saveWork?.cancel()
        if isDirty { save() }
    }

    func save() {
        saveWork?.cancel()
        guard let url, isDirty, !externalConflict else { return }
        let doc = MarkdownDocument(title: title, synopsis: synopsis, status: status, publish: publish,
                                   body: body, extraLines: extraLines)
        // Sans en-tête YAML à l'origine : on écrit le texte seul si rien d'autre n'a changé (et toujours pour un poème).
        let plain = !hasFrontmatter && (poemNumbering || (title == url.deletingPathExtension().lastPathComponent
            && synopsis.isEmpty && status == DocumentStatus.brouillon.rawValue && !publish && extraLines.isEmpty))
        let text = plain ? body : doc.serialized()
        guard text != lastWritten else {
            isDirty = false
            saveState = .saved
            return
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastWritten = text
            isDirty = false
            saveState = .saved
            comments.persist(text: body as NSString)
            if pendingChanges != nil { refreshPendingChanges() }
        } catch {
            saveState = .failed("Enregistrement impossible : \(error.localizedDescription)")
        }
    }

    // MARK: Changements extérieurs (autre application, IA…)

    func fileDidChangeOnDisk() {
        guard let url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let disk = try? String(contentsOf: url, encoding: .utf8), disk != lastWritten else { return }
        if isDirty {
            saveWork?.cancel()
            externalConflict = true
        } else {
            keepSnapshotOfPreviousVersion()
            load()
        }
    }

    func resolveConflictKeepingMine() {
        externalConflict = false
        isDirty = true
        lastWritten = ""
        save()
    }

    func resolveConflictTakingDisk() {
        externalConflict = false
        keepSnapshotOfPreviousVersion()
        load()
    }

    /// Remplace le corps (refus d'une modification) et enregistre aussitôt.
    func replaceBody(_ text: String) {
        body = text
        isDirty = true
        save()
        scheduleStats()
    }

    func reloadView() { reloadToken += 1 }
}

/// Comptes, sommaire et position du curseur — mis à jour souvent, observés par peu de vues.
@MainActor
final class LiveStats: ObservableObject {
    @Published private(set) var wordCount = 0
    @Published private(set) var characterCount = 0
    @Published private(set) var headings: [EditorModel.Heading] = []
    @Published var sessionStartCount = 0
    /// Titre courant (le dernier titre avant le curseur).
    @Published private(set) var currentHeadingID: Int?
    /// Style du paragraphe du curseur, affiché dans la barre d'édition.
    @Published private(set) var currentBlock = BlockStyle.corps
    /// Mots sélectionnés (0 sans sélection).
    @Published private(set) var selectionWordCount = 0
    private var caretLocation = 0

    func reset() {
        apply(EditorModel.Stats(words: 0, characters: 0, headings: []))
        selectionWordCount = 0
        caretLocation = 0
        if currentBlock != .corps { currentBlock = .corps }
    }

    func apply(_ stats: EditorModel.Stats) {
        if wordCount != stats.words { wordCount = stats.words }
        if characterCount != stats.characters { characterCount = stats.characters }
        if headings != stats.headings { headings = stats.headings }
        if paragraphs != stats.paragraphs { paragraphs = stats.paragraphs }
        let level = stats.headings.map(\.level).min() ?? 1
        let first = stats.headings.first?.id
        if level != partLevel || first != firstHeadingID {
            partLevel = level
            firstHeadingID = first
            onPartLayout?(level, first, stats.headings.map(\.id))
        }
        if titleHeading != stats.titleHeading {
            titleHeading = stats.titleHeading
            onTitleHeading?(titleHeading)
        }
        updateCurrentHeading()
    }

    /// Curseur ou sélection modifiés : seules les valeurs réellement changées sont publiées.
    func selectionChanged(_ range: NSRange, in text: NSString) {
        caretLocation = range.location
        updateCurrentHeading()
        let block = BlockStyle.at(range.location, in: text)
        if block != currentBlock { currentBlock = block }
        let words = range.length == 0 ? 0 : WordCounter.count(text.substring(with: range))
        if words != selectionWordCount { selectionWordCount = words }
    }

    @Published private(set) var paragraphs: [Int] = []
    private(set) var titleHeading: Int?
    private(set) var partLevel = 1
    private(set) var firstHeadingID: Int?
    /// Niveau des parties ou premier titre changé : l'éditeur remet en forme les titres (séparateurs).
    var onPartLayout: ((Int, Int?, [Int]) -> Void)?
    /// Appelé quand le titre en double en tête du texte apparaît ou disparaît (pour le masquer dans l'éditeur).
    var onTitleHeading: ((Int?) -> Void)?
    /// Position de lecture dans tout le document (0…1), pour l'index de la règle.
    @Published private(set) var readingFraction: Double = 0

    /// Section en cours de lecture (d'après le défilement) et progression dans cette section (0…1).
    @Published private(set) var readingIndex: Int?
    @Published private(set) var readingProgress: Double = 0

    /// Début et fin (positions) d'une section de titre.
    func sectionBounds(_ index: Int) -> (Int, Int) {
        let start = headings[index].id
        let end = index + 1 < headings.count ? headings[index + 1].id : max(characterCount, start + 1)
        return (start, max(end, start + 1))
    }

    /// Appelé quand la ligne de lecture (le quart haut de la fenêtre) change de position dans le texte.
    func readingMoved(to location: Int) {
        let fraction = characterCount > 0 ? (Double(location) / Double(characterCount) * 1000).rounded() / 1000 : 0
        if fraction != readingFraction { readingFraction = min(1, max(0, fraction)) }
        guard !headings.isEmpty else {
            if readingIndex != nil { readingIndex = nil }
            return
        }
        var low = 0, high = headings.count - 1, found: Int? = nil
        while low <= high {
            let mid = (low + high) / 2
            if headings[mid].id <= location { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        var progress = 0.0
        if let found {
            let (start, end) = sectionBounds(found)
            progress = min(1, max(0, Double(location - start) / Double(end - start)))
            progress = (progress * 200).rounded() / 200 // pas de 0,5 % : pas de mises à jour inutiles
        }
        if found != readingIndex { readingIndex = found }
        if progress != readingProgress { readingProgress = progress }
        let id = found.map { headings[$0].id }
        if id != currentHeadingID { currentHeadingID = id }
    }

    private func updateCurrentHeading() {
        // Recherche dichotomique : le sommaire peut compter des centaines de titres.
        var low = 0, high = headings.count - 1, found: Int? = nil
        while low <= high {
            let mid = (low + high) / 2
            if headings[mid].id <= caretLocation { found = headings[mid].id; low = mid + 1 } else { high = mid - 1 }
        }
        if found != currentHeadingID { currentHeadingID = found }
    }
}
