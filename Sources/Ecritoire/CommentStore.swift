import AppKit
import EcritoireCore

/// Marque posée sur le texte commenté (lue par RichLayoutFragment pour le soulignement et la pastille).
final class CommentMark: NSObject {
    let id: UUID?
    let number: Int
    let resolved: Bool
    let selected: Bool
    init(id: UUID?, number: Int, resolved: Bool, selected: Bool) {
        self.id = id; self.number = number; self.resolved = resolved; self.selected = selected
    }
}

/// Commentaires du document ouvert : chargement, ancrage, suivi des modifications du texte, enregistrement.
@MainActor
final class CommentStore: ObservableObject {
    @Published private(set) var comments: [DocumentComment] = []
    @Published var selectedID: UUID?
    /// Volet en mode « Archives » (commentaires envoyés à Claude ou résolus).
    @Published var showArchive = false
    /// Dernier envoi à Claude (message de confirmation dans le volet).
    @Published var lastSentCount: Int?
    /// Nouveau commentaire en cours d'écriture.
    @Published var draftRange: NSRange?
    @Published var draftQuote = ""
    @Published var draftText = ""
    /// Réponse en cours d'écriture.
    @Published var replyingTo: UUID?
    @Published var replyText = ""
    /// Incrémenté quand le panneau doit donner le focus au champ de saisie.
    @Published private(set) var focusToken = 0

    private(set) var ranges: [UUID: NSRange] = [:]
    private var documentURL: URL?
    private var root: URL?
    /// Appelé avec les plages à remettre en forme (pastilles renumérotées, sélection…).
    var onMarksChanged: (([NSRange]) -> Void)?
    /// Appelé pour montrer un passage dans l'éditeur.
    var onReveal: ((NSRange) -> Void)?
    /// Fournit le texte actuel (pour ancrer un nouveau commentaire).
    var textProvider: (() -> NSString)?

    var visibleComments: [DocumentComment] {
        let list = comments.filter { $0.isArchived == showArchive }
        return list.sorted { (ranges[$0.id]?.location ?? .max, $0.date) < (ranges[$1.id]?.location ?? .max, $1.date) }
    }

    /// Commentaires en cours (ni envoyés ni résolus).
    var openCount: Int { comments.filter { !$0.isArchived }.count }
    var archivedCount: Int { comments.count - openCount }
    var activeComments: [DocumentComment] { comments.filter { !$0.isArchived } }

    /// Numéro affiché : ordre dans le texte parmi les commentaires du même groupe (en cours, ou archivés).
    func number(of id: UUID) -> Int {
        let archived = comments.first { $0.id == id }?.isArchived ?? false
        let ordered = comments.filter { $0.isArchived == archived }.sorted { (ranges[$0.id]?.location ?? .max) < (ranges[$1.id]?.location ?? .max) }
        return (ordered.firstIndex { $0.id == id } ?? 0) + 1
    }

    // MARK: Chargement / enregistrement

    func load(document: URL?, root: URL?, text: NSString) {
        let old = Array(ranges.values)
        documentURL = document
        self.root = root
        draftRange = nil
        replyingTo = nil
        selectedID = nil
        showArchive = false
        lastSentCount = nil
        if let document, let root {
            comments = Sidecar.loadComments(for: document, in: root)
        } else {
            comments = []
        }
        reanchor(text)
        onMarksChanged?(old + Array(ranges.values))
    }

    func relocate(to document: URL) { documentURL = document }

    func reanchor(_ text: NSString) {
        var fresh: [UUID: NSRange] = [:]
        for comment in comments {
            if let r = CommentAnchor.locate(comment, in: text, near: ranges[comment.id]?.location) { fresh[comment.id] = r }
        }
        ranges = fresh
    }

    /// Met à jour les citations d'après les plages actuelles, puis écrit le fichier annexe.
    func persist(text: NSString) {
        guard let documentURL, let root else { return }
        for i in comments.indices {
            guard let r = ranges[comments[i].id], r.length > 0, NSMaxRange(r) <= text.length else { continue }
            comments[i].quote = text.substring(with: r)
            let (p, s) = CommentAnchor.context(of: r, in: text)
            comments[i].prefix = p
            comments[i].suffix = s
        }
        try? Sidecar.saveComments(comments, for: documentURL, in: root)
    }

    private func save() {
        if let text = textProvider?() { persist(text: text) }
    }

    // MARK: Suivi des modifications du texte

    /// `edited` : plage du nouveau texte ; `delta` : variation de longueur.
    func textEdited(_ edited: NSRange, delta: Int) {
        guard !ranges.isEmpty || draftRange != nil else { return }
        let oldEdit = NSRange(location: edited.location, length: max(0, edited.length - delta))
        func shift(_ r: NSRange) -> NSRange {
            if NSMaxRange(oldEdit) <= r.location && !(oldEdit.length == 0 && oldEdit.location == r.location && r.length > 0) {
                return NSRange(location: r.location + delta, length: r.length)
            }
            if oldEdit.location >= NSMaxRange(r) { return r }
            let start = r.location <= oldEdit.location ? r.location : edited.location
            let end = NSMaxRange(r) >= NSMaxRange(oldEdit) ? NSMaxRange(r) + delta : NSMaxRange(edited)
            return NSRange(location: start, length: max(0, end - start))
        }
        for (id, r) in ranges { ranges[id] = shift(r) }
        if let d = draftRange { draftRange = shift(d) }
    }

    // MARK: Actions

    func startDraft(range: NSRange, in text: NSString) {
        guard range.length > 0 else { return }
        let old = draftRange
        draftRange = range
        draftQuote = text.substring(with: range)
        draftText = ""
        selectedID = nil
        focusToken += 1
        onMarksChanged?([range] + (old.map { [$0] } ?? []))
    }

    func cancelDraft() {
        guard let r = draftRange else { return }
        draftRange = nil
        draftText = ""
        onMarksChanged?([r])
    }

    func commitDraft() {
        guard let r = draftRange, let text = textProvider?(), NSMaxRange(r) <= text.length else { return }
        let body = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let (p, s) = CommentAnchor.context(of: r, in: text)
        let comment = DocumentComment(quote: text.substring(with: r), prefix: p, suffix: s, text: body)
        comments.append(comment)
        ranges[comment.id] = r
        draftRange = nil
        draftText = ""
        selectedID = comment.id
        save()
        onMarksChanged?(Array(ranges.values))
    }

    func select(_ id: UUID?, reveal: Bool = true) {
        let old = selectedID.flatMap { ranges[$0] }
        selectedID = id
        let new = id.flatMap { ranges[$0] }
        onMarksChanged?([old, new].compactMap { $0 })
        if reveal, let new { onReveal?(new) }
    }

    func toggleResolved(_ id: UUID) {
        guard let i = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[i].resolved.toggle()
        if selectedID == id { selectedID = nil }
        save()
        onMarksChanged?(Array(ranges.values))
    }

    /// Envoi à Claude : les commentaires en cours passent en archive (ils quittent le texte et le volet).
    func archiveSent(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let now = Date()
        for i in comments.indices where ids.contains(comments[i].id) { comments[i].sent = now }
        if let selectedID, ids.contains(selectedID) { self.selectedID = nil }
        replyingTo = nil
        lastSentCount = ids.count
        save()
        onMarksChanged?(Array(ranges.values))
    }

    /// Sort un commentaire des archives : il redevient un commentaire en cours.
    func restore(_ id: UUID) {
        guard let i = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[i].sent = nil
        comments[i].resolved = false
        save()
        onMarksChanged?(Array(ranges.values))
    }

    /// Bascule entre les commentaires en cours et les archives.
    func setShowArchive(_ on: Bool) {
        guard on != showArchive else { return }
        let old = selectedID.flatMap { ranges[$0] }
        showArchive = on
        selectedID = nil
        replyingTo = nil
        onMarksChanged?(Array(ranges.values) + (old.map { [$0] } ?? []))
    }

    func delete(_ id: UUID) {
        let r = ranges[id]
        comments.removeAll { $0.id == id }
        ranges[id] = nil
        if selectedID == id { selectedID = nil }
        save()
        onMarksChanged?(Array(ranges.values) + (r.map { [$0] } ?? []))
    }

    func startReply(_ id: UUID) {
        replyingTo = id
        replyText = ""
        focusToken += 1
    }

    func commitReply() {
        guard let id = replyingTo, let i = comments.firstIndex(where: { $0.id == id }) else { return }
        let body = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        comments[i].replies.append(.init(text: body))
        replyingTo = nil
        replyText = ""
        save()
    }

    // MARK: Marques pour l'éditeur

    /// Commentaires (et brouillon) qui touchent une plage de texte, avec leur marque d'affichage.
    func marks(in paragraph: NSRange) -> [(NSRange, CommentMark)] {
        var out: [(NSRange, CommentMark)] = []
        // Dans le texte : les commentaires en cours ; en consultant les archives, seulement celui qu'on regarde.
        for comment in comments where !comment.isArchived || (showArchive && comment.id == selectedID) {
            guard let r = ranges[comment.id], r.length > 0,
                  NSIntersectionRange(r, paragraph).length > 0 || NSLocationInRange(r.location, paragraph) else { continue }
            out.append((r, CommentMark(id: comment.id, number: number(of: comment.id), resolved: comment.isArchived,
                                       selected: comment.id == selectedID)))
        }
        if let d = draftRange, NSIntersectionRange(d, paragraph).length > 0 {
            out.append((d, CommentMark(id: nil, number: 0, resolved: false, selected: true)))
        }
        return out
    }

    /// Commentaire sous une position du texte (clic dans le texte commenté).
    func comment(at location: Int) -> UUID? {
        for (id, range) in ranges where NSLocationInRange(location, range) {
            let archived = comments.first { $0.id == id }?.isArchived ?? false
            if !archived { return id }
        }
        return nil
    }
}
