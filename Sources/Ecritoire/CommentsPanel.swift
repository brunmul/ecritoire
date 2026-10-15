import AppKit
import SwiftUI
import EcritoireCore

/// Panneau de droite : fils de commentaires, façon Figma, et préparation du prompt pour Claude.
struct CommentsPanel: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var store: CommentStore
    @FocusState private var draftFocused: Bool
    @FocusState private var replyFocused: Bool
    @StateObject private var copied = HoverState() // « Copié ! » éphémère

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                if store.showArchive {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { store.setShowArchive(false) } } label: {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Revenir aux commentaires en cours")
                    Image(systemName: "archivebox").font(.system(size: 12)).foregroundStyle(UI.icon)
                    Text("Archives").font(UI.fontBold).foregroundStyle(Color(Palette.text))
                } else {
                    Image(systemName: "text.bubble").font(.system(size: 12)).foregroundStyle(UI.icon)
                    Text("Commentaires").font(UI.fontBold).foregroundStyle(Color(Palette.text))
                }
                let count = store.showArchive ? store.archivedCount : store.openCount
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(Palette.secondaryText))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color(Palette.border), in: Capsule())
                }
                Spacer()
                Button { editor.toggleCommentsPanel() } label: {
                    Image(systemName: "xmark").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(UI.icon)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Masquer le volet (⌥⌘C) — le bouton bulle de la barre d'outils le rouvre")
            }
            .padding(.horizontal, 12)
            .frame(height: UI.barHeight)
            .overlay(alignment: .bottom) { Hairline() }

            if !store.showArchive {
                claudeCard
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if store.draftRange != nil && !store.showArchive { draftCard }
                        ForEach(store.visibleComments) { comment in
                            card(comment).id(comment.id)
                        }
                        if store.visibleComments.isEmpty && store.draftRange == nil {
                            VStack(spacing: 8) {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 22, weight: .light))
                                    .foregroundStyle(UI.icon)
                                Text(store.showArchive ? "Aucun commentaire archivé." : "Aucun commentaire en cours.\nSélectionnez un passage puis « Commenter » (⌥⌘M).")
                                    .font(UI.small)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(Color(Palette.secondaryText))
                            }
                            .padding(.top, 40)
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .onChange(of: store.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(Color(Palette.panelLavender))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PanelFooter {
                if store.showArchive {
                    Text("Envoyés ou résolus").lineLimit(1)
                    Spacer()
                    Button("En cours (\(store.openCount))") { withAnimation(.easeInOut(duration: 0.2)) { store.setShowArchive(false) } }
                        .buttonStyle(.link)
                } else {
                    Text(store.openCount == 0 ? "Aucun commentaire en cours" : "\(store.openCount) en cours")
                    Spacer()
                    if store.archivedCount > 0 {
                        Button("Archives (\(store.archivedCount))") { withAnimation(.easeInOut(duration: 0.2)) { store.setShowArchive(true) } }
                            .buttonStyle(.link)
                            .help("Revoir les commentaires envoyés à Claude ou résolus")
                    }
                }
            }
        }
        .onChange(of: store.focusToken) { _, _ in
            DispatchQueue.main.async {
                if store.draftRange != nil { draftFocused = true } else if store.replyingTo != nil { replyFocused = true }
            }
        }
    }

    // MARK: Claude

    private var claudeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    editor.copyClaudePrompt()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { copied.isOn = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { copied.isOn = false } }
                } label: {
                    Label(copied.isOn ? "Prompt copié !" : "Envoyer à Claude\(store.openCount > 0 ? " (\(store.openCount))" : "")",
                          systemImage: copied.isOn ? "checkmark" : "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.openCount == 0 && !copied.isOn)
                .help("Copie un seul prompt avec tous les commentaires en cours et le texte intégral, garde un instantané du texte, puis archive ces commentaires")
                Menu {
                    Button("Envoyer (copier le prompt)") { editor.copyClaudePrompt() }.disabled(store.openCount == 0)
                    Button("Envoyer (enregistrer le prompt dans un fichier)…") { editor.saveClaudePrompt() }.disabled(store.openCount == 0)
                    Divider()
                    Button("Créer un instantané (point de comparaison)") { editor.takeSnapshot() }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let sent = store.lastSentCount {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(Palette.accent))
                    Text("\(sent) commentaire\(sent > 1 ? "s" : "") envoyé\(sent > 1 ? "s" : "") à Claude, rangé\(sent > 1 ? "s" : "") dans les archives.")
                        .font(.caption)
                        .foregroundStyle(Color(Palette.secondaryText))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Voir") { withAnimation(.easeInOut(duration: 0.2)) { store.setShowArchive(true) } }
                        .buttonStyle(.link)
                        .font(.caption.weight(.semibold))
                }
            } else if store.openCount > 0 {
                Text("Les commentaires envoyés passent en archive.")
                    .font(.caption)
                    .foregroundStyle(Color(Palette.secondaryText))
            }
            if let n = editor.pendingChanges {
                HStack(spacing: 6) {
                    Image(systemName: n > 0 ? "arrow.triangle.2.circlepath" : "camera")
                        .foregroundStyle(Color(n > 0 ? NSColor.diffInserted : Palette.secondaryText))
                    Text(n > 0 ? "\(n) modification\(n > 1 ? "s" : "") depuis l'instantané" : "Instantané pris — en attente de modifications")
                        .font(.caption)
                        .foregroundStyle(Color(Palette.secondaryText))
                    Spacer()
                    if n > 0 && editor.review == nil {
                        Button("Voir") { editor.enterReview() }
                            .buttonStyle(.link)
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .padding(8)
        .background(Color(Palette.page), in: RoundedRectangle(cornerRadius: UI.radius))
        .overlay(RoundedRectangle(cornerRadius: UI.radius).stroke(Color(Palette.border)))
    }

    // MARK: Cartes

    private var draftCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PinBadge(number: 0, resolved: false)
                quote(store.draftQuote)
            }
            TextField("Votre commentaire…", text: $store.draftText, axis: .vertical)
                .lineLimit(2...8)
                .textFieldStyle(.plain)
                .font(UI.font)
                .focused($draftFocused)
                .onSubmit { store.commitDraft() }
                .padding(8)
                .background(Color(Palette.page), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(Palette.accent).opacity(0.6)))
            HStack {
                Spacer()
                Button("Annuler") { store.cancelDraft() }
                    .keyboardShortcut(.cancelAction)
                Button("Commenter") { store.commitDraft() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(Palette.page), in: RoundedRectangle(cornerRadius: UI.radius))
        .overlay(RoundedRectangle(cornerRadius: UI.radius).stroke(Color(Palette.accent), lineWidth: 1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func card(_ comment: DocumentComment) -> some View {
        let selected = store.selectedID == comment.id
        let anchored = store.ranges[comment.id] != nil
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                PinBadge(number: store.number(of: comment.id), resolved: comment.isArchived)
                VStack(alignment: .leading, spacing: 2) {
                    if anchored {
                        quote(comment.quote)
                    } else {
                        Text("Passage introuvable — « \(comment.quote) »")
                            .font(.caption).italic()
                            .foregroundStyle(Color(NSColor.diffDeletedText))
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if let reference = store.ranges[comment.id].flatMap({ editor.verseReference(for: $0) }) {
                            Text(reference)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color(Palette.accent))
                        }
                        Text(archiveStatus(comment) ?? comment.date.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(Color(Palette.secondaryText))
                    }
                }
            }
            Text(comment.text)
                .font(UI.font)
                .foregroundStyle(Color(Palette.text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(comment.replies) { reply in
                HStack(alignment: .top, spacing: 6) {
                    Rectangle().fill(Color(Palette.border)).frame(width: 2)
                    Text(reply.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(Palette.text))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if store.replyingTo == comment.id {
                TextField("Répondre…", text: $store.replyText, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($replyFocused)
                    .onSubmit { store.commitReply() }
                    .padding(7)
                    .background(Color(Palette.page), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(Palette.border)))
            }
            HStack(spacing: 2) {
                if comment.isArchived {
                    ToolIcon(systemImage: "arrow.uturn.backward.circle", help: "Restaurer : redevient un commentaire en cours") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { store.restore(comment.id) }
                    }
                } else {
                    ToolIcon(systemImage: "arrowshape.turn.up.left", help: "Répondre") { store.startReply(comment.id) }
                    ToolIcon(systemImage: "checkmark.circle", help: "Résolu : ranger dans les archives") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { store.toggleResolved(comment.id) }
                    }
                }
                Spacer()
                ToolIcon(systemImage: "trash", help: "Supprimer") {
                    withAnimation(.easeOut(duration: 0.2)) { store.delete(comment.id) }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: UI.radius).fill(selected ? Color(Palette.selection) : Color(Palette.page)))
        .overlay(RoundedRectangle(cornerRadius: UI.radius).stroke(Color(Palette.border), lineWidth: 1))
        .opacity(comment.isArchived ? 0.8 : 1)
        .scaleEffect(selected ? 1.01 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selected)
        .contentShape(Rectangle())
        .onTapGesture { store.select(comment.id) }
    }

    /// « Envoyé à Claude le 9 oct. à 16:40 » ou « Résolu » pour un commentaire archivé.
    private func archiveStatus(_ comment: DocumentComment) -> String? {
        if let sent = comment.sent {
            return "Envoyé à Claude " + sent.formatted(.relative(presentation: .named))
        }
        return comment.resolved ? "Résolu" : nil
    }

    private func quote(_ text: String) -> some View {
        Text(text.replacingOccurrences(of: "\n", with: " "))
            .font(Palette.serif(13, weight: .regular)).italic()
            .foregroundStyle(Color(Palette.secondaryText))
            .lineLimit(2)
    }
}

struct PinBadge: View {
    let number: Int
    let resolved: Bool
    var body: some View {
        Text(number == 0 ? "+" : "\(number)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Color(resolved ? Palette.secondaryText : Palette.accent), in: Circle())
    }
}

/// Barre du mode « Modifications » : navigation et décisions.
struct ReviewBar: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        if let review = editor.review {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color(NSColor.diffInserted))
                Text("Modification \(review.current + 1) sur \(review.changes.count)")
                    .font(UI.font)
                    .monospacedDigit()
                    .foregroundStyle(Color(Palette.text))
                    .frame(minWidth: 150, alignment: .leading)
                ToolIcon(systemImage: "chevron.up", help: "Précédente (⌥⌘↑)") { editor.selectChange(max(0, review.current - 1)) }
                ToolIcon(systemImage: "chevron.down", help: "Suivante (⌥⌘↓)") { editor.selectChange(min(review.changes.count - 1, review.current + 1)) }
                BubbleDivider()
                Button { editor.acceptCurrentChange() } label: { Label("Accepter", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).tint(Color(NSColor.diffInserted))
                    .help("Garder cette modification (⌥⌘Y)")
                Button { editor.rejectCurrentChange() } label: { Label("Refuser", systemImage: "xmark") }
                    .buttonStyle(.bordered)
                    .help("Revenir au texte d'avant pour ce passage (⌥⌘N)")
                BubbleDivider()
                Menu("Tout") {
                    Button("Tout accepter") { editor.acceptAllChanges() }
                    Button("Tout refuser") { editor.rejectAllChanges() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("Terminer") { editor.exitReview() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(Palette.page), in: RoundedRectangle(cornerRadius: UI.radius))
            .overlay(RoundedRectangle(cornerRadius: UI.radius).stroke(Color(Palette.border)))
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color(Palette.desk))
        }
    }
}

/// Bandeau discret quand le document a changé depuis l'instantané.
struct ChangesBanner: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        if let n = editor.pendingChanges, n > 0, editor.review == nil {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(UI.icon)
                Text("Ce document a été modifié : \(n) modification\(n > 1 ? "s" : "") depuis l'instantané.")
                    .foregroundStyle(Color(Palette.text))
                Spacer()
                Button("Voir les modifications") { editor.enterReview() }
                    .buttonStyle(.bordered)
                Button("Ignorer") { editor.discardSnapshot() }
                    .help("La version actuelle devient la référence")
            }
            .controlSize(.small)
            .font(UI.font)
            .padding(.horizontal, 12)
            .frame(minHeight: UI.barHeight)
            .background(Color(Palette.desk))
            .overlay(alignment: .bottom) { Hairline() }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Volet des commentaires à droite, affiché selon `EditorModel.commentsPanelShown` (jamais vide tout seul).
struct CommentsSidebar: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var store: CommentStore

    var body: some View {
        let shown = editor.commentsPanelShown
        HStack(spacing: 0) {
            if shown {
                Rectangle().fill(Color(Palette.border)).frame(width: 1)
                CommentsPanel(editor: editor, store: store)
                    .frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: shown)
    }
}

/// Bouton bulle de la barre d'outils : affiche ou cache le volet ; pastille = commentaires en cours.
struct CommentsToolbarButton: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var store: CommentStore

    var body: some View {
        Button { editor.toggleCommentsPanel() } label: {
            Label {
                Text("Commentaires")
            } icon: {
                Image(systemName: editor.commentsPanelShown ? "text.bubble.fill" : "text.bubble")
                    .overlay(alignment: .topTrailing) {
                        if store.openCount > 0 {
                            Text("\(store.openCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3.5)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(Color(Palette.accent), in: Capsule())
                                .offset(x: 8, y: -7)
                        }
                    }
            }
        }
        .help(editor.commentsPanelShown ? "Masquer les commentaires (⌥⌘C)" : "Afficher les commentaires (⌥⌘C)")
        .disabled(editor.url == nil)
    }
}
