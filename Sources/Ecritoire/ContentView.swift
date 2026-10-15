import AppKit
import SwiftUI
import EcritoireCore

struct ContentView: View {
    @EnvironmentObject var workspace: Workspace
    @ObservedObject var editor: EditorModel
    @AppStorage("machineAEcrire") private var typewriterAlways = false
    @AppStorage("zoom") private var zoom = 1.0
    @AppStorage("sommaire") private var showOutline = true
    @AppStorage("largeurSommaire") private var outlineWidth = 290.0

    var body: some View {
        Group {
            if workspace.rootURL == nil {
                WelcomeView()
            } else {
                split
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .tint(Color(Palette.accent))
        .background(Color(Palette.desk))
        .overlay {
            if let message = workspace.importProgress {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(message)
                }
                .font(UI.font)
                .padding(18)
                .background(Color(Palette.sidebar), in: RoundedRectangle(cornerRadius: UI.radius))
                .overlay(RoundedRectangle(cornerRadius: UI.radius).stroke(Color(Palette.border)))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            }
        }
        .alert("Opération impossible", isPresented: Binding(
            get: { workspace.errorMessage != nil },
            set: { if !$0 { workspace.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.errorMessage ?? "")
        }
    }

    private var split: some View {
        NavigationSplitView(columnVisibility: $workspace.columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 400)
        } detail: {
            HStack(spacing: 0) {
                if showOutline && !workspace.focusMode {
                    OutlinePanel(editor: editor, live: editor.live)
                        .frame(width: outlineWidth)
                    ResizeHandle(width: $outlineWidth, range: 200...520)
                }
                EditorPane(editor: editor, typewriter: typewriterAlways || workspace.focusMode, zoom: $zoom)
                if !workspace.focusMode && editor.url != nil {
                    CommentsSidebar(editor: editor, store: editor.comments)
                }
            }
        }
        .inspector(isPresented: $workspace.showInspector) {
            InspectorView(editor: editor)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
        }
        .toolbarBackground(Color(Palette.header), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        // Titre du document dans la barre de la fenêtre ; « Renommer… » (menu du titre) renomme aussi le fichier.
        .navigationTitle(Binding(
            get: { editor.url == nil ? workspace.binderName : editor.displayTitle },
            set: { newValue in renameDocument(to: newValue) }
        ))
        .toolbarRole(.editor)
        .navigationSubtitle(editor.url == nil ? "" : workspace.binderName)
        .toolbar(workspace.focusMode ? .hidden : .visible, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showOutline.toggle() } } label: {
                    Label("Sommaire", systemImage: "list.bullet.indent")
                }
                .help("Afficher ou masquer le sommaire (⌥⌘S)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if editor.url != nil {
                    Picker("Affichage", selection: Binding(get: { editor.poemDisplay }, set: { editor.setPoemDisplay($0) })) {
                        Text("Prose").tag(false)
                        Text("Poème").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("Affichage prose ou poème (mémorisé pour ce document)")
                }
                CommentsToolbarButton(editor: editor, store: editor.comments)
                Button { workspace.focusMode = true } label: {
                    Label("Mode focus", systemImage: "rectangle.center.inset.filled")
                }
                .help("Mode focus (⇧⌘↩)")
                Button { workspace.showInspector.toggle() } label: {
                    Label("Inspecteur", systemImage: "sidebar.right")
                }
                .help("Afficher ou masquer l'inspecteur (⌥⌘I)")
            }
        }
        .onChange(of: workspace.focusMode) { _, focus in applyFocus(focus) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            if workspace.focusMode { workspace.focusMode = false }
        }
    }

    private func renameDocument(to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = editor.url, !name.isEmpty, name != editor.displayTitle else { return }
        editor.title = name
        editor.flush()
        workspace.rename(url, to: name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -"))
    }

    private func applyFocus(_ focus: Bool) {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
        if focus {
            workspace.inspectorBeforeFocus = workspace.showInspector
            workspace.showInspector = false
            withAnimation { workspace.columns = .detailOnly }
            if !isFullScreen { window?.toggleFullScreen(nil) }
        } else {
            withAnimation { workspace.columns = .all }
            workspace.showInspector = workspace.inspectorBeforeFocus
            if isFullScreen { window?.toggleFullScreen(nil) }
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(UI.icon)
            Text("Écritoire")
                .font(Palette.serif(30))
                .foregroundStyle(Color(Palette.text))
            Text("Un classeur est un simple dossier de fichiers Markdown.\nChoisissez-en un existant, ou un dossier vide pour commencer.")
                .font(UI.font)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(Palette.secondaryText))
                .lineSpacing(3)
            HStack(spacing: 12) {
                Button("Importer un projet Scrivener…") { workspace.importScrivener() }
                    .buttonStyle(.bordered)
                Button("Ouvrir un classeur…") { workspace.chooseBinder() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(36)
        .background(Color(Palette.page), in: RoundedRectangle(cornerRadius: UI.radius))
        .overlay(RoundedRectangle(cornerRadius: UI.radius).stroke(Color(Palette.border)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(Palette.desk))
    }
}

struct Sidebar: View {
    @EnvironmentObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: workspace.sidebarMode == .recherche ? "magnifyingglass" : "books.vertical")
                    .font(.system(size: 12))
                    .foregroundStyle(UI.icon)
                Text(workspace.sidebarMode == .recherche ? "Recherche" : workspace.binderName)
                    .font(UI.fontBold)
                    .foregroundStyle(Color(Palette.text))
                    .lineLimit(1)
                Spacer()
                Button {
                    if workspace.sidebarMode == .recherche { workspace.sidebarMode = .classeur } else { workspace.showSearch() }
                } label: {
                    Image(systemName: workspace.sidebarMode == .recherche ? "books.vertical" : "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(UI.icon)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(workspace.sidebarMode == .recherche ? "Revenir au classeur" : "Rechercher dans les titres et le texte (⇧⌘F)")
            }
            .padding(.horizontal, 12)
            .frame(height: UI.barHeight)
            .overlay(alignment: .bottom) { Hairline() }
            if workspace.sidebarMode == .recherche {
                SearchPanel(search: workspace.search)
            } else {
                BinderOutline(workspace: workspace)
            }
        }
        .background(Color(Palette.panelLavender))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Button { workspace.newDocument() } label: { Image(systemName: "doc.badge.plus") }
                    .help("Nouveau document (⌘N)")
                Button { workspace.newFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .help("Nouveau dossier (⇧⌘N)")
                Spacer()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(UI.icon)
            .padding(.horizontal, 12)
            .frame(height: UI.barHeight)
            .background(Color(Palette.panelLavender))
            .overlay(alignment: .top) { Hairline() }
        }
    }
}

struct EditorPane: View {
    @EnvironmentObject var workspace: Workspace
    @ObservedObject var editor: EditorModel
    var typewriter: Bool
    @Binding var zoom: Double

    var body: some View {
        VStack(spacing: 0) {
            if editor.externalConflict {
                ConflictBanner(editor: editor)
            }
            ChangesBanner(editor: editor)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: editor.pendingChanges)
            if editor.review != nil {
                ReviewBar(editor: editor)
            } else if editor.url != nil && !workspace.focusMode {
                FormatBar(live: editor.live) { command in editor.commandTarget?.perform(command) }
            }
            ZStack {
                MarkdownEditor(editor: editor, typewriter: typewriter, zoom: zoom,
                               onEscape: workspace.focusMode ? { workspace.focusMode = false } : nil)
                if editor.url == nil {
                    Text("Sélectionnez ou créez un document")
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            if editor.url != nil {
                StatusBar(editor: editor, live: editor.live, zoom: $zoom, discreet: workspace.focusMode)
            }
        }
    }
}

struct ConflictBanner: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Ce document a été modifié en dehors d'Écritoire pendant que vous écriviez.")
            Spacer()
            Button("Garder ma version") { editor.resolveConflictKeepingMine() }
            Button("Recharger depuis le disque") { editor.resolveConflictTakingDisk() }
        }
        .font(UI.font)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(minHeight: UI.barHeight)
        .background(Color(Palette.desk))
        .overlay(alignment: .bottom) { Hairline() }
    }
}

struct StatusBar: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var live: LiveStats
    @Binding var zoom: Double
    var discreet: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZoomControl(zoom: $zoom)
            Text(Self.format(live.wordCount, "mot", "mots"))
                .monospacedDigit()
            Text(Self.format(live.characterCount, "caractère", "caractères"))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            if live.selectionWordCount > 0 {
                Text(Self.format(live.selectionWordCount, "mot sélectionné", "mots sélectionnés"))
                    .monospacedDigit()
                    .foregroundStyle(Color(Palette.text))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color(Palette.textSelection), in: Capsule())
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            let delta = live.wordCount - live.sessionStartCount
            if delta != 0 {
                Text("\(delta > 0 ? "+" : "−")\(abs(delta)) cette session")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !discreet {
                saveLabel
            }
        }
        .font(UI.small)
        .foregroundStyle(Color(Palette.secondaryText))
        .padding(.horizontal, 12)
        .frame(height: UI.barHeight)
        .background(Color(Palette.desk))
        .overlay(alignment: .top) { Hairline().opacity(discreet ? 0 : 1) }
        .opacity(discreet ? 0.7 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: live.selectionWordCount > 0)
    }

    @ViewBuilder private var saveLabel: some View {
        switch editor.saveState {
        case .saved: Label("Enregistré", systemImage: "checkmark.circle").labelStyle(.titleAndIcon)
            .foregroundStyle(Color(Palette.secondaryText))
        case .modified: Label("Modifié", systemImage: "circle.dotted").foregroundStyle(Color(Palette.secondaryText))
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    static func format(_ n: Int, _ singular: String, _ plural: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "fr_FR")
        return "\(formatter.string(from: NSNumber(value: n)) ?? "\(n)") \(n > 1 ? plural : singular)"
    }
}

struct InspectorView: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        if editor.url == nil {
            Text("Aucun document")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                Section("Document") {
                    TextField("Titre", text: $editor.title)
                    TextField("Synopsis", text: $editor.synopsis, axis: .vertical)
                        .lineLimit(3...8)
                    Picker("Statut", selection: $editor.status) {
                        ForEach(statusChoices, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    Toggle("Publier sur le wiki", isOn: $editor.publish)
                }
                Section("Fichier") {
                    LabeledContent("Nom", value: editor.url?.lastPathComponent ?? "")
                    WordCountLabel(live: editor.live)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color(Palette.panelLavender))
        }
    }

    /// Les statuts proposés, plus la valeur actuelle si elle a été écrite à la main avec un autre mot.
    private var statusChoices: [String] {
        let base = DocumentStatus.allCases.map(\.rawValue)
        return base.contains(editor.status) ? base : base + [editor.status]
    }
}

/// Curseur de zoom de la zone d'écriture (50 % à 200 %), comme dans Scrivener.
struct ZoomControl: View {
    @Binding var zoom: Double

    var body: some View {
        HStack(spacing: 6) {
            Button { zoom = max(0.5, ((zoom - 0.1) * 10).rounded() / 10) } label: { Image(systemName: "minus") }
                .help("Dézoomer (⌘−)")
            Slider(value: Binding(get: { zoom }, set: { zoom = ($0 * 20).rounded() / 20 }), in: 0.5...2.0)
                .frame(width: 110)
                .controlSize(.mini)
            Button { zoom = min(2.0, ((zoom + 0.1) * 10).rounded() / 10) } label: { Image(systemName: "plus") }
                .help("Zoomer (⌘+)")
            Button { zoom = 1 } label: {
                Text("\(Int((zoom * 100).rounded())) %")
                    .monospacedDigit()
                    .frame(minWidth: 40, alignment: .leading)
            }
            .help("Revenir à 100 % (⌘0)")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

/// En-tête de panneau latéral : titre en serif.
struct PanelHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(UI.icon)
            Text(title)
                .font(UI.fontBold)
                .foregroundStyle(Color(Palette.text))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: UI.barHeight)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// Second panneau : le sommaire, organisé autour d'une règle graduée qui représente tout le document.
///
/// Petits crans = paragraphes, grands crans = titres (plus longs pour les niveaux supérieurs), chacun relié
/// à sa ligne de titre. L'index lavande montre la position de lecture ; glisser sur la règle fait défiler
/// le document en direct, et l'index s'aimante aux titres (avec un léger retour haptique du trackpad).
struct OutlinePanel: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var live: LiveStats

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Sommaire", systemImage: "list.bullet.indent")
            if live.headings.isEmpty && live.paragraphs.isEmpty {
                Text(editor.url == nil ? "Aucun document" : "Document vide")
                    .font(.callout)
                    .foregroundStyle(Color(Palette.secondaryText))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    ScrollView(.vertical, showsIndicators: false) {
                        OutlineRuler(editor: editor, live: live, width: geo.size.width - 12, height: geo.size.height - 16)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
        .background(Color(Palette.panelLavender))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PanelFooter {
                if !live.headings.isEmpty {
                    let unit = editor.poemDisplay && editor.poemNumbering ? "verset" : "titre"
                    Text("\(live.headings.count) \(unit)\(live.headings.count > 1 ? "s" : "")")
                }
            }
        }
    }
}

/// Correspondance (non linéaire) entre le document et la hauteur de la règle : chaque titre est à la
/// hauteur exacte de sa ligne dans le sommaire ; entre deux titres, les paragraphes de la section se
/// répartissent régulièrement. Les sections longues reçoivent un peu plus de place si le panneau le permet.
struct RulerGeometry {
    struct Section {
        let start: Int          // début (position du titre, ou 0 pour le début du document)
        let end: Int
        let heading: Int?       // indice du titre, nil pour le texte avant le premier titre
        let tickY: CGFloat      // hauteur du cran (= centre de la ligne de titre)
        let zoneEnd: CGFloat    // fin de la zone de la section sur la règle
        let paragraphs: [Int]   // débuts de paragraphes dans la section
    }

    let sections: [Section]
    let height: CGFloat
    /// Hauteurs des séparateurs ondulés entre deux parties de premier niveau.
    let separators: [CGFloat]

    init(headings: [EditorModel.Heading], paragraphs: [Int], length: Int, height available: CGFloat, rowHeight: CGFloat) {
        let length = max(length, 1)
        var bounds: [(Int, Int, Int?)] = []
        // Le texte éventuel avant le premier titre n'a pas de crans : la règle commence au premier titre.
        for (i, h) in headings.enumerated() {
            bounds.append((h.id, i + 1 < headings.count ? headings[i + 1].id : length, i))
        }
        if bounds.isEmpty { bounds = [(0, length, nil)] }
        let minimum = rowHeight
        let total = max(available, CGFloat(bounds.count) * minimum + rowHeight)
        let spare = total - CGFloat(bounds.count) * minimum
        let sum = Double(bounds.reduce(0) { $0 + max($1.1 - $1.0, 1) })
        // Un peu d'air avant chaque partie de premier niveau (et un peu moins avant le niveau 2).
        let minLevel = headings.map(\.level).min() ?? 1
        func gap(_ heading: Int?) -> CGFloat {
            guard let heading else { return 0 }
            switch headings[heading].level - minLevel {
            case 0: return 18
            case 1: return 6
            default: return 0
            }
        }
        let gaps = bounds.map { _ in CGFloat(0) } // lignes à pas régulier : pas d'espace supplémentaire
        _ = gap
        let spare2 = max(0, spare - gaps.reduce(0, +))
        var y: CGFloat = 0
        var sections: [Section] = []
        var separators: [CGFloat] = []
        var p = 0
        for (index, (start, end, heading)) in bounds.enumerated() {
            if gaps[index] > 0 {
                if let heading, headings[heading].level == minLevel { separators.append(y + gaps[index] / 2) }
                // La zone de la section précédente s'étend sur l'espace ajouté : la graduation reste continue.
                if var last = sections.popLast() {
                    last = Section(start: last.start, end: last.end, heading: last.heading, tickY: last.tickY,
                                   zoneEnd: last.zoneEnd + gaps[index], paragraphs: last.paragraphs)
                    sections.append(last)
                }
                y += gaps[index]
            }
            // Pas régulier : chaque section a la même hauteur (une ligne, ou plus si le panneau est grand),
            // donc aucun « trou » après les titres des longues sections.
            _ = spare2; _ = sum
            let h = max(minimum, min(available / CGFloat(bounds.count), minimum * 2.2))
            while p < paragraphs.count && paragraphs[p] < start { p += 1 }
            var inside: [Int] = []
            var q = p
            while q < paragraphs.count && paragraphs[q] < end { inside.append(paragraphs[q]); q += 1 }
            let tick = heading == nil ? y : y + rowHeight / 2
            sections.append(Section(start: start, end: end, heading: heading, tickY: tick, zoneEnd: y + h, paragraphs: inside))
            y += h
        }
        self.sections = sections
        self.height = y
        self.separators = separators
    }

    /// Début et fin de la règle (du premier grand cran à la fin du document).
    var top: CGFloat { sections.first?.tickY ?? 0 }
    var bottom: CGFloat { sections.last?.zoneEnd ?? 0 }

    /// Hauteur sur la règle d'une position du texte.
    func y(for location: Int) -> CGFloat {
        guard let first = sections.first else { return 0 }
        if location < first.start { return first.tickY }
        guard let s = sections.last(where: { $0.start <= location }) else { return 0 }
        let zone = s.zoneEnd - s.tickY
        let m = s.paragraphs.count
        guard m > 0 else {
            return s.tickY + zone * CGFloat(Double(location - s.start) / Double(max(s.end - s.start, 1)))
        }
        let k = (s.paragraphs.lastIndex { $0 <= location }) ?? -1
        let from = k >= 0 ? s.paragraphs[k] : s.start
        let to = k + 1 < m ? s.paragraphs[k + 1] : s.end
        let frac = Double(location - from) / Double(max(to - from, 1))
        return s.tickY + zone * CGFloat((Double(k + 1) + frac) / Double(m + 1))
    }

    /// Position du texte correspondant à une hauteur de la règle.
    func location(for y: CGFloat) -> Int {
        guard let s = sections.last(where: { $0.tickY <= y }) ?? sections.first else { return 0 }
        let zone = max(s.zoneEnd - s.tickY, 1)
        let m = s.paragraphs.count
        let t = Double(min(max(y - s.tickY, 0), zone) / zone)
        guard m > 0 else { return s.start + Int(Double(s.end - s.start) * t) }
        let scaled = t * Double(m + 1) - 1
        let k = Int(floor(scaled))
        let from = k >= 0 ? s.paragraphs[min(k, m - 1)] : s.start
        let to = k + 1 < m ? s.paragraphs[k + 1] : s.end
        let frac = scaled - Double(k)
        return from + Int(Double(max(to - from, 0)) * min(max(frac, 0), 1))
    }

    func tickY(heading index: Int) -> CGFloat? { sections.first { $0.heading == index }?.tickY }
}

struct OutlineRuler: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var live: LiveStats
    let width: CGFloat
    let height: CGFloat
    @StateObject private var drag = DragState()

    static let rowHeight: CGFloat = 24
    static let rulerWidth: CGFloat = 34
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    final class DragState: ObservableObject {
        @Published var location: Int?   // position de l'index pendant un glisser
        @Published var hovering = false
        var lastSnapped: Int?
    }

    var body: some View {
        let geometry = RulerGeometry(headings: live.headings, paragraphs: live.paragraphs, length: live.characterCount,
                                     height: height, rowHeight: Self.rowHeight)
        let readingLocation = drag.location ?? Int(live.readingFraction * Double(live.characterCount))
        let minLevel = live.headings.map(\.level).min() ?? 1
        ZStack(alignment: .topLeading) {
            // Règle : petits crans régulièrement répartis entre deux titres, grands crans à hauteur des titres.
            Canvas { context, size in
                let ruleX = Self.rulerWidth - 4
                // La règle va du premier titre à la fin du document, rien au-dessus ni en dessous.
                let ruleTop = geometry.top, ruleBottom = geometry.bottom
                var spine = Path()
                spine.move(to: CGPoint(x: ruleX, y: ruleTop))
                spine.addLine(to: CGPoint(x: ruleX, y: ruleBottom))
                // Règle discrète ; elle se renforce un peu au survol ou pendant le glissé.
                let strength: Double = (drag.hovering || drag.location != nil) ? 1.6 : 1
                context.stroke(spine, with: .color(Color(Palette.border).opacity(0.7 * strength)), lineWidth: 1)
                // Trame continue : un cran fin tous les 4 points, sur toute la hauteur.
                var grid = Path()
                var gy: CGFloat = ruleTop + 4
                while gy < ruleBottom - 1 {
                    grid.move(to: CGPoint(x: ruleX - 3, y: gy))
                    grid.addLine(to: CGPoint(x: ruleX, y: gy))
                    gy += 4
                }
                context.stroke(grid, with: .color(Color(Palette.accent).opacity(0.16 * strength)), lineWidth: 0.6)
                // Cran de fin du document.
                var endTick = Path()
                endTick.move(to: CGPoint(x: ruleX - 9, y: ruleBottom))
                endTick.addLine(to: CGPoint(x: ruleX, y: ruleBottom))
                context.stroke(endTick, with: .color(Color(Palette.secondaryText).opacity(0.45 * strength)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                // Paragraphes : crans un peu plus longs posés sur la trame.
                var small = Path()
                for section in geometry.sections {
                    let zone = section.zoneEnd - section.tickY
                    let m = section.paragraphs.count
                    guard m > 0 else { continue }
                    let step = max(1, Int(ceil(4 / max(zone / CGFloat(m + 1), 0.01))))
                    for k in stride(from: 0, to: m, by: step) {
                        let py = section.tickY + zone * CGFloat(k + 1) / CGFloat(m + 1)
                        small.move(to: CGPoint(x: ruleX - 5, y: py))
                        small.addLine(to: CGPoint(x: ruleX, y: py))
                    }
                }
                context.stroke(small, with: .color(Color(Palette.secondaryText).opacity(0.3 * strength)), lineWidth: 0.8)
                for (i, heading) in live.headings.enumerated() {
                    guard let hy = geometry.tickY(heading: i) else { continue }
                    let depth = CGFloat(heading.level - minLevel)
                    let length = max(6, 13 - depth * 3)
                    let current = i == live.readingIndex
                    var tick = Path()
                    tick.move(to: CGPoint(x: ruleX - length, y: hy))
                    tick.addLine(to: CGPoint(x: ruleX + 10, y: hy)) // le cran se prolonge jusqu'au titre
                    context.stroke(tick, with: .color(current ? Color(Palette.accent) : Color(Palette.secondaryText).opacity(0.55 * strength)),
                                   lineWidth: depth == 0 ? 1.5 : 1.1)
                }
            }
            .frame(width: Self.rulerWidth + 14, height: geometry.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in scrub(to: value.location.y, ending: false, geometry: geometry) }
                .onEnded { value in scrub(to: value.location.y, ending: true, geometry: geometry) })
            .onHover { drag.hovering = $0 }
            .help("Glisser pour parcourir le document ; l'index s'aimante aux titres")

            // Index de lecture (vue à part pour que son déplacement soit animé).
            ReadingIndex()
                .frame(width: Self.rulerWidth, height: 12)
                .offset(y: geometry.y(for: readingLocation) - 6)
                .allowsHitTesting(false)

            // Lignes de titre, chacune centrée sur son cran.
            ForEach(Array(live.headings.enumerated()), id: \.element.id) { i, heading in
                let current = i == live.readingIndex
                let rowTop = (geometry.tickY(heading: i) ?? 0) - Self.rowHeight / 2
                Button { editor.jump(to: heading) } label: {
                    Text(heading.title)
                        .font(heading.level == minLevel ? UI.font : .system(size: 12.5))
                        .foregroundStyle(Color(heading.level == minLevel || current ? Palette.text : Palette.secondaryText))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: UI.radius).fill(Color(Palette.selection).opacity(current ? 1 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(heading.title)
                .frame(width: max(60, width - Self.rulerWidth - 22), alignment: .leading)
                .padding(.leading, Self.rulerWidth + 10) // dans la mise en page (un décalage serait rogné par la vue de défilement)
                .offset(y: rowTop)
            }
        }
        .frame(height: geometry.height, alignment: .top)
        .padding(.horizontal, 6)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.78), value: readingLocation)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: live.readingIndex)
    }

    /// Glisser sur la règle : défilement en direct, aimantation aux titres proches.
    private func scrub(to position: CGFloat, ending: Bool, geometry: RulerGeometry) {
        let clamped = min(max(position, 0), geometry.height)
        var location = geometry.location(for: clamped)
        var snapped: Int? = nil
        let snapDistance: CGFloat = ending ? 12 : 6
        let ticks = live.headings.indices.compactMap { i in geometry.tickY(heading: i).map { (i, $0) } }
        if let nearest = ticks.min(by: { abs($0.1 - clamped) < abs($1.1 - clamped) }), abs(nearest.1 - clamped) < snapDistance {
            snapped = nearest.0
            location = live.headings[nearest.0].id
        }
        if let snapped, snapped != drag.lastSnapped {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        drag.lastSnapped = snapped
        editor.scrollHandler?(location, ending && !reduceMotion)
        if ending {
            drag.location = nil
            drag.lastSnapped = nil
        } else {
            drag.location = location
        }
    }
}

/// Index lavande de la règle : triangle et trait jusqu'à la règle.
struct ReadingIndex: View {
    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            var tri = Path()
            tri.move(to: CGPoint(x: 4, y: mid - 4.5))
            tri.addLine(to: CGPoint(x: 11, y: mid))
            tri.addLine(to: CGPoint(x: 4, y: mid + 4.5))
            tri.closeSubpath()
            context.fill(tri, with: .color(Color(Palette.accent)))
            var line = Path()
            line.move(to: CGPoint(x: 10, y: mid))
            line.addLine(to: CGPoint(x: size.width - 2, y: mid))
            context.stroke(line, with: .color(Color(Palette.accent)), lineWidth: 1.5)
        }
    }
}

/// Séparateur vertical qu'on peut glisser pour régler la largeur du panneau à sa gauche (largeur mémorisée).
struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @StateObject private var start = DragStart()

    final class DragStart: ObservableObject { var width: Double? }

    var body: some View {
        Rectangle()
            .fill(Color(Palette.border))
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let base = start.width ?? width
                            start.width = base
                            width = min(max(base + value.translation.width, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in start.width = nil })
            )
    }
}

final class HoverState: ObservableObject {
    @Published var isOn = false
}

struct WordCountLabel: View {
    @ObservedObject var live: LiveStats
    var body: some View {
        LabeledContent("Mots", value: StatusBar.format(live.wordCount, "mot", "mots"))
    }
}

/// Barre d'édition au-dessus de la page : style de paragraphe, gras/italique, surligneurs, liste, citation, lien.
struct FormatBar: View {
    @ObservedObject var live: LiveStats
    let perform: (EditorCommand) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(BlockStyle.allCases) { style in
                    Button(style.label) { perform(.block(style)) }
                }
            } label: {
                Text(live.currentBlock.label)
                    .font(UI.font)
                    .foregroundStyle(Color(Palette.text))
                    .frame(minWidth: 96, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8)
            .help("Style du paragraphe (⌥⌘0 à ⌥⌘3)")
            BubbleDivider()
            ToolIcon(systemImage: "bold", help: "Gras (⌘B)") { perform(.bold) }
            ToolIcon(systemImage: "italic", help: "Italique (⌘I)") { perform(.italic) }
            BubbleDivider()
            ForEach(HighlightColor.allCases) { color in
                HighlightDot(color: color) { perform(.highlight(color)) }
            }
            ToolIcon(systemImage: "eraser", help: "Retirer le surlignage") { perform(.eraseHighlight) }
            BubbleDivider()
            ToolIcon(systemImage: "list.bullet", help: "Liste", isActive: live.currentBlock == .liste) {
                perform(.block(live.currentBlock == .liste ? .corps : .liste))
            }
            ToolIcon(systemImage: "text.quote", help: "Citation", isActive: live.currentBlock == .citation) {
                perform(.block(live.currentBlock == .citation ? .corps : .citation))
            }
            ToolIcon(systemImage: "link", help: "Lien interne [[…]] (⌘K)") { perform(.wikiLink) }
            BubbleDivider()
            ToolIcon(systemImage: "text.bubble", help: "Commenter la sélection (⌥⌘M)") { perform(.comment) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Color(Palette.page), in: RoundedRectangle(cornerRadius: UI.radius))
        .overlay(RoundedRectangle(cornerRadius: UI.radius).stroke(Color(Palette.border)))
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color(Palette.desk))
    }
}
