import AppKit
import SwiftUI
import EcritoireCore

/// Mode « Recherche » du volet de gauche : champ, portée, résultats groupés par document avec leur contexte.
struct SearchPanel: View {
    @EnvironmentObject var workspace: Workspace
    @ObservedObject var search: SearchController
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let results = search.results {
                            ForEach(results.documents) { doc in
                                documentBlock(doc)
                            }
                        } else {
                            placeholder
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: search.selection) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(Color(Palette.panelLavender))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PanelFooter {
                if search.indexing {
                    ProgressView().controlSize(.mini)
                    Text("Indexation…")
                } else if let r = search.results {
                    Text(r.totalHits == 0 && r.documents.isEmpty ? "Aucun résultat"
                         : "\(Self.number(r.totalHits)) occurrence\(r.totalHits > 1 ? "s" : "") · \(r.documents.count) document\(r.documents.count > 1 ? "s" : "")")
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f ms", r.milliseconds)).monospacedDigit()
                } else {
                    Text("Titres et texte, sans tenir compte des accents")
                        .lineLimit(1)
                }
            }
        }
        .onAppear {
            search.active = true
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: search.focusToken) { _, _ in DispatchQueue.main.async { fieldFocused = true } }
    }

    static func number(_ n: Int) -> String {
        n >= SearchIndex.countLimit ? "\(n.formatted())+" : n.formatted()
    }

    // MARK: Champ

    private var field: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(UI.icon)
                TextField("Rechercher", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(UI.font)
                    .focused($fieldFocused)
                    .onKeyPress(.downArrow) { search.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { search.moveSelection(-1); return .handled }
                    .onKeyPress(.return) { openSelected(); return .handled }
                    .onKeyPress(.escape) {
                        if search.query.isEmpty { workspace.sidebarMode = .classeur } else { search.query = "" }
                        return .handled
                    }
                if !search.query.isEmpty {
                    Button { search.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color(Palette.secondaryText))
                    }
                    .buttonStyle(.borderless)
                    .help("Effacer")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color(Palette.page), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(fieldFocused ? Color(Palette.accent).opacity(0.7) : Color(Palette.border)))
            Picker("Portée", selection: $search.scope) {
                Text("Ce classeur").tag(SearchController.Scope.classeur)
                Text("Tous les classeurs").tag(SearchController.Scope.tous)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plusieurs mots : tous présents, dans n'importe quel ordre.")
            Text("« phrase exacte » entre guillemets.")
            Text("Début de mot : « dialect » trouve « dialectique ».")
            Text("↑ ↓ pour parcourir, Entrée pour ouvrir.")
        }
        .font(UI.small)
        .foregroundStyle(Color(Palette.secondaryText))
        .padding(14)
    }

    // MARK: Résultats

    private func documentBlock(_ doc: SearchIndex.DocumentResult) -> some View {
        let hits = search.hits(of: doc)
        return VStack(alignment: .leading, spacing: 0) {
            Button { open(doc, nil) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(UI.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(doc.title)
                            .font(Font(EditorTheme(size: 13.5).font(.grotesk, bold: true) as CTFont))
                            .foregroundStyle(Color(doc.titleMatches ? Palette.accentStrong : Palette.text))
                            .lineLimit(1)
                        Text(Self.folderPath(doc.relativePath))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color(Palette.secondaryText))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 4)
                    if doc.count > 0 {
                        Text(Self.number(doc.count))
                            .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Color(Palette.secondaryText))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color(Palette.border), in: Capsule())
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(rowBackground(doc.id))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(doc.id)
            ForEach(hits) { hit in
                Button { open(doc, hit) } label: { hitRow(hit) }
                    .buttonStyle(.plain)
                    .id(hit.id)
            }
            if doc.count > hits.count && search.expanded[doc.id] == nil {
                Button("Afficher les autres (\(Self.number(doc.count - hits.count)))") { search.expand(doc) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .padding(.leading, 28).padding(.vertical, 3)
            }
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(Palette.border).opacity(0.6)).frame(height: 1).padding(.horizontal, 10) }
    }

    private func hitRow(_ hit: SearchIndex.Hit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label = hit.verse ?? hit.heading {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(Palette.secondaryText))
                    .lineLimit(1)
            }
            Text(context(hit))
                .font(Font((hit.isHeading ? EditorTheme(size: 13).font(.grotesk, bold: true) : EditorTheme(size: 13.5).font(.serif)) as CTFont))
                .foregroundStyle(Color(Palette.text))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 28).padding(.trailing, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(hit.id))
        .contentShape(Rectangle())
    }

    private func rowBackground(_ id: String) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(Palette.selection).opacity(search.selection == id ? 1 : 0))
            .padding(.horizontal, 4)
    }

    /// Contexte avec le terme surligné en jaune (coup de feutre de l'éditeur).
    private func context(_ hit: SearchIndex.Hit) -> AttributedString {
        // Le terme doit rester visible dans les 4 lignes : début de phrase raccourci au besoin.
        var shortBefore = hit.before
        if shortBefore.count > 90 {
            let tail = shortBefore.suffix(90)
            shortBefore = "…" + (tail.firstIndex(of: " ").map { String(tail[tail.index(after: $0)...]) } ?? String(tail))
        }
        var before = AttributedString(shortBefore)
        before.foregroundColor = Color(Palette.secondaryText)
        var match = AttributedString(hit.match)
        match.backgroundColor = Color(HighlightColor.jaune.nsColor.withAlphaComponent(0.55))
        var after = AttributedString(hit.after)
        after.foregroundColor = Color(Palette.secondaryText)
        return before + match + after
    }

    /// « Partie/Chapitre.md » → « Partie ».
    static func folderPath(_ relative: String) -> String {
        let parts = relative.split(separator: "/").dropLast()
        return parts.isEmpty ? "—" : parts.joined(separator: " › ")
    }

    private func open(_ doc: SearchIndex.DocumentResult, _ hit: SearchIndex.Hit?) {
        search.selection = hit?.id ?? doc.id
        workspace.openSearchResult(doc.url, range: hit?.range)
    }

    private func openSelected() {
        guard let item = search.selectedItem else { return }
        open(item.doc, item.hit)
    }
}
