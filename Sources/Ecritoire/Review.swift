import AppKit
import EcritoireCore

/// Vue fusionnée « avant / après » : le texte supprimé reste en place (barré), le texte ajouté est marqué.
struct ReviewState {
    struct Change {
        let hunk: DiffHunk
        /// Plages dans le texte fusionné.
        let deletedRange: NSRange
        let insertedRange: NSRange
        var whole: NSRange { NSUnionRange(deletedRange, insertedRange) }
    }

    let base: String
    let merged: String
    let changes: [Change]
    var current: Int = 0
    let token = UUID()

    init(base: String, current: String, hunks: [DiffHunk]) {
        self.base = base
        let text = current as NSString
        var merged = ""
        var mergedLength = 0
        var cursor = 0
        var changes: [Change] = []
        for hunk in hunks {
            let before = text.substring(with: NSRange(location: cursor, length: hunk.currentRange.location - cursor))
            merged += before
            mergedLength += (before as NSString).length
            let del = NSRange(location: mergedLength, length: (hunk.deleted as NSString).length)
            merged += hunk.deleted
            mergedLength += del.length
            let ins = NSRange(location: mergedLength, length: (hunk.inserted as NSString).length)
            merged += hunk.inserted
            mergedLength += ins.length
            changes.append(Change(hunk: hunk, deletedRange: del, insertedRange: ins))
            cursor = NSMaxRange(hunk.currentRange)
        }
        merged += text.substring(from: cursor)
        self.merged = merged
        self.changes = changes
    }

    /// Marques de modification qui touchent une plage du texte fusionné.
    func marks(in paragraph: NSRange) -> [(NSRange, DiffMark)] {
        var out: [(NSRange, DiffMark)] = []
        // Recherche dichotomique du premier changement qui peut toucher le paragraphe.
        var low = 0, high = changes.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(changes[mid].whole) < paragraph.location { low = mid + 1 } else { high = mid }
        }
        var i = low
        while i < changes.count, changes[i].whole.location <= NSMaxRange(paragraph) {
            let c = changes[i]
            if c.deletedRange.length > 0 { out.append((c.deletedRange, DiffMark(kind: .deleted, index: i, current: i == current))) }
            if c.insertedRange.length > 0 { out.append((c.insertedRange, DiffMark(kind: .inserted, index: i, current: i == current))) }
            i += 1
        }
        return out
    }

    func change(at location: Int) -> Int? {
        changes.firstIndex { NSLocationInRange(location, $0.whole) || (location == NSMaxRange($0.whole) && $0.whole.length > 0) }
    }
}

final class DiffMark: NSObject {
    enum Kind { case inserted, deleted }
    let kind: Kind
    let index: Int
    let current: Bool
    init(kind: Kind, index: Int, current: Bool) { self.kind = kind; self.index = index; self.current = current }
}

extension EditorModel {
    // MARK: Instantané (version de référence pour les modifications)

    private func snapshotBody() -> String? {
        guard let url, let root = binderRoot, let text = Sidecar.loadSnapshot(for: url, in: root) else { return nil }
        return MarkdownDocument.parse(text).body
    }

    /// Garde la version actuelle comme référence (avant de la confier à Claude, par exemple).
    func takeSnapshot() {
        guard let url, let root = binderRoot else { return }
        flush()
        try? Sidecar.saveSnapshot(lastWritten.isEmpty ? (try? String(contentsOf: url, encoding: .utf8)) : lastWritten,
                                  for: url, in: root)
        snapshotDate = Date()
        pendingChanges = 0
    }

    /// Un autre programme vient de modifier le fichier : sans instantané, on garde la version d'avant.
    func keepSnapshotOfPreviousVersion() {
        guard let url, let root = binderRoot, !lastWritten.isEmpty, Sidecar.loadSnapshot(for: url, in: root) == nil else { return }
        try? Sidecar.saveSnapshot(lastWritten, for: url, in: root)
    }

    /// Oublie l'instantané : la version actuelle devient la référence.
    func discardSnapshot() {
        guard let url, let root = binderRoot else { return }
        try? Sidecar.saveSnapshot(nil, for: url, in: root)
        pendingChanges = nil
        if review != nil { exitReview() }
    }

    /// Compte les modifications depuis l'instantané, en arrière-plan.
    func refreshPendingChanges() {
        guard let base = snapshotBody() else { pendingChanges = nil; return }
        diffGeneration += 1
        let generation = diffGeneration
        let current = body
        DispatchQueue.global(qos: .userInitiated).async {
            let count = TextDiff.hunks(from: base, to: current).count
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.diffGeneration else { return }
                self.pendingChanges = count
            }
        }
    }

    // MARK: Mode « Modifications »

    func enterReview(keeping index: Int = 0) {
        guard let base = snapshotBody() else { return }
        flush()
        diffGeneration += 1
        let generation = diffGeneration
        let current = body
        DispatchQueue.global(qos: .userInitiated).async {
            let hunks = TextDiff.hunks(from: base, to: current)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.diffGeneration else { return }
                self.pendingChanges = hunks.count
                if hunks.isEmpty {
                    self.discardSnapshot()
                    return
                }
                var state = ReviewState(base: base, current: current, hunks: hunks)
                state.current = min(index, hunks.count - 1)
                self.review = state
            }
        }
    }

    func exitReview() {
        review = nil
        reloadView()
    }

    func selectChange(_ index: Int) {
        guard var state = review, state.changes.indices.contains(index) else { return }
        state.current = index
        review = state
    }

    func acceptCurrentChange() {
        guard let state = review, state.changes.indices.contains(state.current), let url, let root = binderRoot else { return }
        let newBase = TextDiff.accept(state.changes[state.current].hunk, base: state.base)
        // L'instantané garde l'en-tête de la version de référence ; seul le corps change.
        var doc = MarkdownDocument.parse(Sidecar.loadSnapshot(for: url, in: root) ?? "")
        doc.body = newBase
        try? Sidecar.saveSnapshot(doc.serialized(), for: url, in: root)
        enterReview(keeping: state.current)
    }

    func rejectCurrentChange() {
        guard let state = review, state.changes.indices.contains(state.current) else { return }
        replaceBody(TextDiff.reject(state.changes[state.current].hunk, current: body))
        comments.reanchor(body as NSString)
        enterReview(keeping: state.current)
    }

    func acceptAllChanges() {
        discardSnapshot()
    }

    func rejectAllChanges() {
        guard let base = snapshotBody() else { return }
        replaceBody(base)
        comments.reanchor(body as NSString)
        discardSnapshot()
    }

    // MARK: Préparer pour Claude

    /// Référence des versets d'un passage (« v. 12 », « v. 9–11 »), pour un poème en versets numérotés.
    func verseReference(for range: NSRange) -> String? {
        guard poemNumbering else { return nil }
        return Poem.reference(for: range, in: body)
    }

    /// Prompt complet : consignes, chemin, commentaires numérotés avec leur passage, texte intégral.
    func claudePrompt() -> String {
        flush()
        let path = url?.path ?? ""
        let file = (try? url.map { try String(contentsOf: $0, encoding: .utf8) }) ?? nil
        let open = comments.activeComments.sorted { comments.number(of: $0.id) < comments.number(of: $1.id) }
        var out = """
        # Révision demandée — « \(title.isEmpty ? (url?.deletingPathExtension().lastPathComponent ?? "") : title) »

        Tu travailles sur un document Markdown d'Écritoire, mon outil d'écriture :
        `\(path)`

        ## Consignes
        - Modifie directement ce fichier pour traiter chacun des commentaires numérotés ci-dessous.
        - Ne change que ce que les commentaires demandent ; laisse tout le reste mot pour mot.
        - Conserve l'en-tête YAML et la syntaxe : titres `#`, encadrés `> [!intro]`, citations `>`, surlignages `==…==` et `<mark class="…">`, images `![[…]]`, liens `[[…]]`.
        \(poemNumbering ? "- C'est un poème en versets : un verset = un paragraphe, précédé de sa position `[n]`. Garde ce format (une ligne vide entre deux versets) et renumérote si tu ajoutes, supprimes ou fusionnes des versets ; les références « v. n » désignent ces numéros.\n" : "")- N'invente ni faits ni citations. Si un commentaire est ambigu, fais le choix le plus prudent et signale-le.
        - Ne modifie pas le dossier caché `.ecritoire` (commentaires et instantanés).
        - À la fin, résume en une ligne par commentaire ce que tu as changé.

        ## Commentaires (\(open.count))

        """
        let text = body as NSString
        for comment in open {
            let n = comments.number(of: comment.id)
            let reference = comments.ranges[comment.id].flatMap { verseReference(for: $0) }
            out += "### \(n). \(reference.map { "\($0) — " } ?? "")« \(comment.quote) »\n"
            if let r = comments.ranges[comment.id], NSMaxRange(r) <= text.length {
                let (p, s) = CommentAnchor.context(of: r, in: text)
                out += "Contexte : …\(p.replacingOccurrences(of: "\n", with: " "))**\(comment.quote)**\(s.replacingOccurrences(of: "\n", with: " "))…\n"
            } else {
                out += "(Ce passage n'a pas été retrouvé dans la version actuelle.)\n"
            }
            out += "Commentaire : \(comment.text)\n"
            for reply in comment.replies { out += "Précision : \(reply.text)\n" }
            out += "\n"
        }
        out += """
        ## Texte intégral actuel

        ````markdown
        \(file ?? body)
        ````

        """
        return out
    }

    /// Envoi à Claude : copie le prompt (tous les commentaires en cours), garde un instantané pour voir ensuite
    /// ce que Claude aura modifié, et passe ces commentaires en archive.
    func copyClaudePrompt() {
        sendToClaude { prompt in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
        }
    }

    /// `deliver` reçoit le prompt (presse-papiers, fichier…) ; les commentaires envoyés sont ensuite archivés.
    func sendToClaude(_ deliver: (String) -> Void) {
        let sent = comments.activeComments.map(\.id)
        let prompt = claudePrompt()
        deliver(prompt)
        takeSnapshot()
        commentsPanelForced = true // le volet reste ouvert sur la confirmation
        comments.archiveSent(sent)
    }

    /// Écrit le prompt dans `.ecritoire/prompts/` (pour Claude Code ou Claude desktop) et le montre dans le Finder.
    @discardableResult
    func saveClaudePrompt() -> URL? {
        guard let url, let root = binderRoot else { return nil }
        let sent = comments.activeComments.map(\.id)
        let prompt = claudePrompt()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH'h'mm"
        let folder = root.appendingPathComponent(Sidecar.folderName).appendingPathComponent(Sidecar.Kind.prompts.rawValue)
        let file = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) — \(formatter.string(from: Date())).md")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try prompt.write(to: file, atomically: true, encoding: .utf8)
        } catch { return nil }
        takeSnapshot()
        commentsPanelForced = true
        comments.archiveSent(sent)
        NSWorkspace.shared.activateFileViewerSelecting([file])
        return file
    }
}
