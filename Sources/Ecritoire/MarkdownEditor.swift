import AppKit
import SwiftUI

/// NSTextView (TextKit 2) avec colonne de texte centrée et défilement « machine à écrire ».
final class WritingTextView: NSTextView {
    var columnWidth: CGFloat = 640 { didSet { updateInsets() } }
    var typewriter = false {
        didSet {
            guard typewriter != oldValue else { return }
            updateInsets()
            if typewriter { centerCaret(animated: false) }
        }
    }
    var onEscape: (() -> Void)?

    // Curseur dessiné par l'application (voir WritingTextView+Caret.swift).
    let caretLayer = CALayer()
    /// Filet dans la marge gauche + léger fond chaud sur le paragraphe du curseur.
    let paragraphBar = CALayer()
    let paragraphTint = CALayer()
    var paragraphShown = false
    var paragraphLocation = -1
    var hoverTracking: NSTrackingArea?
    /// Vérifications automatiques : afficher le curseur même si la fenêtre n'est pas au premier plan.
    var forceCaretForCapture = false
    var caretVisible = false
    var keyObservers: [NSObjectProtocol] = []
    // Bulle d'outils au-dessus de la sélection.
    var bubble: NSView?
    var makeBubble: (() -> NSView)?
    var bubbleWork: DispatchWorkItem?
    // Sélection « aimantée » au mot puis au paragraphe pendant un glisser.
    var isDraggingSelection = false
    // Commentaires et relecture.
    var onComment: ((NSRange) -> Void)?
    /// Clic simple dans le texte (position) ; clic dans la marge droite (identifiant de la pastille).
    var onTextClick: ((Int) -> Void)?
    var onPinClick: ((UUID) -> Void)?
    /// Poème en versets numérotés : Retour, Effacer et le curseur respectent les numéros masqués.
    var poemEditing = false
    /// Marge minimale de chaque côté de la colonne (plus large en poème, pour les numéros des versets).
    var minimumSideInset: CGFloat = 32 { didSet { if minimumSideInset != oldValue { updateInsets() } } }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
        updateCaret(animated: false)
    }

    func updateInsets() {
        let horizontal = max(minimumSideInset, (bounds.width - columnWidth) / 2)
        let visibleHeight = enclosingScrollView?.contentView.bounds.height ?? 600
        let vertical = typewriter ? max(40, visibleHeight / 2 - 20) : 72
        let inset = NSSize(width: horizontal.rounded(), height: vertical.rounded())
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        if typewriter {
            centerCaret(animated: false)
        } else {
            super.scrollRangeToVisible(range)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        if typewriter { centerCaret(animated: false) }
        hideBubble()
        updateCaret(animated: true, typing: true)
    }

    /// Fait défiler pour garder la ligne du curseur au milieu de la fenêtre.
    func centerCaret(animated: Bool) {
        guard let scrollView = enclosingScrollView, let window else { return }
        let caret = NSRange(location: selectedRange().location, length: 0)
        let screenRect = firstRect(forCharacterRange: caret, actualRange: nil)
        guard screenRect != .zero else { return }
        let local = convert(window.convertFromScreen(screenRect), from: nil)
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y = (local.midY - clip.bounds.height / 2).rounded()
        origin.y = max(0, min(origin.y, bounds.height - clip.bounds.height))
        guard abs(origin.y - clip.bounds.origin.y) > 0.5 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    /// Position de lecture : le caractère sur la ligne située au quart haut de la zone visible.
    static let readingLineRatio: CGFloat = 0.25

    func readingLocation() -> Int? {
        guard let scrollView = enclosingScrollView, let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let clip = scrollView.contentView.bounds
        let y = clip.minY + clip.height * Self.readingLineRatio - textContainerOrigin.y
        guard let fragment = tlm.textLayoutFragment(for: CGPoint(x: 1, y: max(0, y))) else { return nil }
        let start = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
        let localY = y - fragment.layoutFragmentFrame.minY
        let line = fragment.textLineFragments.last { $0.typographicBounds.minY <= localY } ?? fragment.textLineFragments.first
        return start + (line?.characterRange.location ?? 0)
    }

    /// Amène `location` sur la ligne de lecture (navigation par le sommaire), sans toucher au curseur.
    func scrollToReadingLine(_ location: Int, animated: Bool) {
        guard let scrollView = enclosingScrollView, let window else { return }
        let length = (string as NSString).length
        let range = NSRange(location: min(max(location, 0), length), length: 0)
        var screenRect = firstRect(forCharacterRange: range, actualRange: nil)
        if screenRect == .zero {
            super.scrollRangeToVisible(range)
            screenRect = firstRect(forCharacterRange: range, actualRange: nil)
        }
        guard screenRect != .zero else { return }
        let local = convert(window.convertFromScreen(screenRect), from: nil)
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y = max(0, min(local.minY - clip.bounds.height * Self.readingLineRatio, bounds.height - clip.bounds.height))
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    /// En dessous de cette longueur, chaque remise en forme est suivie d'une mise en page complète (quelques ms).
    static let fullLayoutLimit = 120_000

    /// Exécute une remise en forme en gardant immobile, à l'écran, le paragraphe qui était en haut de la zone visible.
    func preservingScrollAnchor(_ body: () -> Void) {
        guard let scrollView = enclosingScrollView, let tlm = textLayoutManager, let tcm = tlm.textContentManager else { body(); return }
        let clip = scrollView.contentView
        let probeY = clip.bounds.minY + 4 - textContainerOrigin.y
        guard let anchor = tlm.textLayoutFragment(for: CGPoint(x: 1, y: max(0, probeY))) else { body(); return }
        let anchorOffset = tcm.offset(from: tcm.documentRange.location, to: anchor.rangeInElement.location)
        let screenDelta = anchor.layoutFragmentFrame.minY + textContainerOrigin.y - clip.bounds.minY
        body()
        // Document court (un poème, un chapitre) : mise en page complète, jamais de hauteurs estimées —
        // sinon TextKit 2 place le texte à côté de sa vraie position et la page saute au défilement.
        if (string as NSString).length < Self.fullLayoutLimit { tlm.ensureLayout(for: tlm.documentRange) }
        defer { tlm.textViewportLayoutController.layoutViewport() }
        guard let location = tcm.location(tcm.documentRange.location, offsetBy: anchorOffset) else { return }
        tlm.ensureLayout(for: NSTextRange(location: location))
        guard let moved = tlm.textLayoutFragment(for: location) else { return }
        let newY = moved.layoutFragmentFrame.minY + textContainerOrigin.y - screenDelta
        if abs(newY - clip.bounds.minY) > 0.5 {
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: max(0, newY)))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// Fait défiler (sans toucher à la sélection) pour montrer `location` au tiers haut de l'écran.
    func scrollToShow(_ location: Int) {
        let length = (string as NSString).length
        let range = NSRange(location: min(max(location, 0), length), length: 0)
        super.scrollRangeToVisible(range)
        DispatchQueue.main.async { [weak self] in
            guard let self, let scrollView = self.enclosingScrollView, let window = self.window else { return }
            let screenRect = self.firstRect(forCharacterRange: range, actualRange: nil)
            guard screenRect != .zero else { return }
            let local = self.convert(window.convertFromScreen(screenRect), from: nil)
            let clip = scrollView.contentView
            var origin = clip.bounds.origin
            origin.y = max(0, min(local.minY - clip.bounds.height / 3, self.bounds.height - clip.bounds.height))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
                clip.animator().setBoundsOrigin(origin)
            }
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// Place le curseur à `location` et fait défiler pour amener cette ligne en haut de la page.
    func reveal(location: Int) {
        let length = (string as NSString).length
        let range = NSRange(location: min(max(location, 0), length), length: 0)
        window?.makeFirstResponder(self)
        setSelectedRange(range)
        super.scrollRangeToVisible(range)
        DispatchQueue.main.async { [weak self] in
            guard let self, let scrollView = self.enclosingScrollView, let window = self.window else { return }
            let screenRect = self.firstRect(forCharacterRange: range, actualRange: nil)
            guard screenRect != .zero else { return }
            let local = self.convert(window.convertFromScreen(screenRect), from: nil)
            let clip = scrollView.contentView
            var origin = clip.bounds.origin
            origin.y = max(0, min(local.minY - 60, self.bounds.height - clip.bounds.height))
            clip.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }
}

/// Fond de l'éditeur : « bureau » teinté et page blanche centrée sous la colonne de texte.
/// Ce sont de simples calques colorés placés derrière le texte, qui ne défilent pas : rien n'est
/// redessiné pendant le défilement (le texte, transparent, glisse par-dessus).
final class PageBackdropView: NSView {
    var columnWidth: CGFloat = 640 { didSet { needsLayout = true } }
    var pagePadding: CGFloat = 72 { didSet { needsLayout = true } }
    private let page = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(page)
        page.borderWidth = 1
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = min(bounds.width, columnWidth + pagePadding * 2)
        page.frame = CGRect(x: ((bounds.width - width) / 2).rounded() - 1, y: -1, width: width + 2, height: bounds.height + 2)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.desk.cgColor
            page.backgroundColor = Palette.page.cgColor
            page.borderColor = Palette.border.cgColor
        }
    }
}

/// Vue de défilement qui garde le fond de page derrière la zone qui défile.
final class PageScrollView: NSScrollView {
    let backdrop = PageBackdropView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        contentView.drawsBackground = false
        addSubview(backdrop, positioned: .below, relativeTo: contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func tile() {
        super.tile()
        backdrop.frame = contentView.frame
    }

    // MARK: Défilement aimanté
    //
    // À la fin d'un défilement (élan compris), la page se cale en douceur sur le début de paragraphe
    // le plus proche du haut de l'écran, comme sur iPadOS. Désactivable (menu Présentation).

    private var snapWork: DispatchWorkItem?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard UserDefaults.standard.object(forKey: "defilementAimante") as? Bool ?? true,
              event.hasPreciseScrollingDeltas else { return }
        if event.momentumPhase == .began || event.phase == .began || event.phase == .changed {
            snapWork?.cancel()
        }
        if event.momentumPhase == .ended {
            snapToParagraph()
        } else if event.phase == .ended {
            // Sans élan, le geste s'arrête là ; avec élan, momentumPhase .began annulera ceci.
            snapWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.snapToParagraph() }
            snapWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }
    }

    func snapToParagraph() {
        guard let textView = documentView as? NSTextView, let tlm = textView.textLayoutManager else { return }
        let clip = contentView
        let margin: CGFloat = 28
        let origin = textView.textContainerOrigin
        let probeY = clip.bounds.minY + margin - origin.y
        guard let fragment = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, probeY))) else { return }
        var candidates = [fragment.layoutFragmentFrame.minY, fragment.layoutFragmentFrame.maxY]
        // Le paragraphe suivant peut être un séparateur vide : on prend le premier vrai paragraphe.
        if let next = tlm.textLayoutFragment(for: CGPoint(x: 0, y: fragment.layoutFragmentFrame.maxY + 6)) {
            candidates.append(next.layoutFragmentFrame.minY)
        }
        let current = probeY
        guard let target = candidates.min(by: { abs($0 - current) < abs($1 - current) }) else { return }
        let distance = target - current
        // Seulement si le début de paragraphe est proche (sinon on est au milieu d'un long paragraphe).
        guard abs(distance) > 1, abs(distance) < min(140, clip.bounds.height * 0.25) else { return }
        var newOrigin = clip.bounds.origin
        newOrigin.y = max(0, min(clip.bounds.minY + distance, textView.bounds.height - clip.bounds.height))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            clip.setBoundsOrigin(newOrigin)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                clip.animator().setBoundsOrigin(newOrigin)
            }
        }
        reflectScrolledClipView(clip)
    }
}

struct MarkdownEditor: NSViewRepresentable {
    @ObservedObject var editor: EditorModel
    var typewriter: Bool
    /// Zoom de la zone d'écriture (1 = 100 %) : taille du texte, largeur de la page et des images.
    var zoom: CGFloat
    var onEscape: (() -> Void)?

    // Réglages repris du Monde diplomatique (même Walbaum 10 XL) : corps ≈ 20 pt, interligne 1,4,
    // colonne d'environ 65-70 caractères, texte gris très foncé.
    static let baseFontSize: CGFloat = 19
    static let baseColumnWidth: CGFloat = 600
    static let basePagePadding: CGFloat = 72
    /// Poème : colonne plus étroite que la prose (≈ 26 em du texte des versets).
    static let basePoemColumnWidth: CGFloat = 540

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = PageScrollView()
        let clip = scrollView.backdrop
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = WritingTextView(usingTextLayoutManager: true)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = true
        textView.drawsBackground = false
        textView.insertionPointColor = Palette.accent
        textView.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
        textView.delegate = context.coordinator
        editor.commandTarget = textView
        context.coordinator.connect(textView)
        textView.makeBubble = { [weak textView] in
            let host = NSHostingView(rootView: SelectionBubble { command in textView?.perform(command) })
            host.setFrameSize(host.fittingSize)
            return host
        }

        let highlighter = context.coordinator.highlighter
        highlighter.fontSize = (Self.baseFontSize * zoom).rounded()
        textView.columnWidth = (Self.baseColumnWidth * zoom).rounded()
        clip.columnWidth = textView.columnWidth
        clip.pagePadding = (Self.basePagePadding * zoom).rounded()
        highlighter.columnWidth = textView.columnWidth
        highlighter.imageProvider = { [weak coordinator = context.coordinator] name in coordinator?.image(named: name) }
        context.coordinator.fragments.highlighter = highlighter
        textView.textLayoutManager?.delegate = context.coordinator.fragments
        textView.textStorage?.delegate = highlighter
        textView.typingAttributes = highlighter.baseAttributes

        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.scrolled() }
        }
        scrollView.contentView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak textView] _ in
            MainActor.assumeIsolated { textView?.updateInsets() }
        }
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? WritingTextView else { return }
        let coordinator = context.coordinator
        textView.onEscape = onEscape
        textView.isEditable = editor.url != nil && editor.review == nil

        // Sortie du mode « Modifications » : le rechargement qui suit remet le vrai texte.
        if editor.review == nil, coordinator.review != nil {
            coordinator.review = nil
            coordinator.highlighter.showAllMarkers = false
        }

        let fontSize = (Self.baseFontSize * zoom).rounded()
        let poem = editor.poemDisplay
        let column = ((poem ? Self.basePoemColumnWidth : Self.baseColumnWidth) * zoom).rounded()
        var restyle = false
        textView.poemEditing = poem && editor.poemNumbering
        // Numéros des versets : filet (1,1 em) + numéro + un peu d'air, dans la marge.
        textView.minimumSideInset = poem ? (fontSize * 3.6).rounded() : 32
        if coordinator.highlighter.poemMode != poem {
            coordinator.highlighter.poemMode = poem
            restyle = true
        }
        if textView.columnWidth != column, let clip = (scrollView as? PageScrollView)?.backdrop {
            textView.columnWidth = column
            clip.columnWidth = column
            clip.pagePadding = (Self.basePagePadding * zoom).rounded()
            coordinator.highlighter.columnWidth = column
            restyle = true
        }
        if coordinator.highlighter.fontSize != fontSize {
            coordinator.highlighter.fontSize = fontSize
            restyle = true
        }
        // (Un document qui vient d'être chargé est remis en forme plus bas.)
        if restyle, coordinator.loadedToken == editor.reloadToken, let storage = textView.textStorage {
            textView.typingAttributes = coordinator.highlighter.baseAttributes
            coordinator.highlighter.highlightAll(storage)
            if let tlm = textView.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
            DispatchQueue.main.async { textView.updateCaret(animated: false) }
        }

        if coordinator.loadedToken != editor.reloadToken {
            let sameDocument = coordinator.loadedURL == editor.url
            let selection = textView.selectedRange()
            coordinator.loadedToken = editor.reloadToken
            coordinator.loadedURL = editor.url
            coordinator.isLoading = true
            if !sameDocument { coordinator.imageCache.removeAll() }
            textView.string = editor.body
            coordinator.isLoading = false
            if let storage = textView.textStorage { coordinator.highlighter.highlightAll(storage) }
            textView.typingAttributes = coordinator.highlighter.baseAttributes
            textView.undoManager?.removeAllActions()
            // Mise en page complète du document : sans elle, TextKit 2 replace les paragraphes modifiés d'après
            // des hauteurs estimées, et curseur, filet et texte divergent sur les longs documents.
            if ProcessInfo.processInfo.environment["SANS_MISE_EN_PAGE_COMPLETE"] == nil, let tlm = textView.textLayoutManager {
                let t0 = CACurrentMediaTime()
                tlm.ensureLayout(for: tlm.documentRange)
                if ProcessInfo.processInfo.environment["MESURE"] != nil {
                    print(String(format: "mise en page complète : %.0f ms", (CACurrentMediaTime() - t0) * 1000))
                }
            }
            textView.hideBubble()
            coordinator.isLoading = true // la sélection posée au chargement n'active pas de paragraphe
            defer { coordinator.isLoading = false }
            if sameDocument {
                // Rechargement après une modification extérieure : on garde le curseur au même endroit.
                let length = (editor.body as NSString).length
                textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            } else {
                // Curseur au début du texte visible (après un éventuel titre en double, masqué).
                var start = 0
                if let hidden = coordinator.highlighter.hiddenTitleLocation {
                    start = NSMaxRange((editor.body as NSString).paragraphRange(for: NSRange(location: hidden, length: 0)))
                }
                textView.setSelectedRange(NSRange(location: start, length: 0))
                textView.scroll(.zero)
                DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
            }
        } else {
            coordinator.loadedURL = editor.url // suit un renommage ou un déplacement du fichier ouvert
        }
        textView.typewriter = typewriter

        // Mode « Modifications » : texte fusionné, lecture seule.
        if let review = editor.review {
            if coordinator.review?.token != review.token {
                coordinator.review = review
                coordinator.highlighter.showAllMarkers = true
                coordinator.isLoading = true
                textView.string = review.merged
                if let storage = textView.textStorage { coordinator.highlighter.highlightAll(storage) }
                textView.hideBubble()
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                coordinator.isLoading = false
                coordinator.reviewCurrent = -1
            }
            if coordinator.reviewCurrent != review.current, review.changes.indices.contains(review.current) {
                let old = coordinator.reviewCurrent
                coordinator.review = review
                coordinator.reviewCurrent = review.current
                var touched = [review.changes[review.current].whole]
                if review.changes.indices.contains(old) { touched.append(review.changes[old].whole) }
                if let storage = textView.textStorage { coordinator.highlighter.rehighlight(touched, in: storage) }
                textView.scrollToShow(review.changes[review.current].whole.location)
            }
        }

        // Clic dans le sommaire : aller au titre.
        if let jump = editor.jumpRequest, jump.id != coordinator.lastJump {
            coordinator.lastJump = jump.id
            textView.reveal(location: jump.location)
            if jump.flash {
                let range = NSRange(location: jump.location, length: jump.length)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak textView] in
                    guard let textView, NSMaxRange(range) <= (textView.string as NSString).length else { return }
                    textView.setSelectedRange(range)
                    textView.showFindIndicator(for: range)
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let editor: EditorModel
        let highlighter = MarkdownHighlighter()
        let fragments = FragmentProvider()
        var imageCache: [String: NSImage] = [:]
        weak var textView: WritingTextView?
        var loadedToken = -1
        var lastJump: UUID?
        var review: ReviewState?
        var reviewCurrent = -1

        /// Branche commentaires, relecture et clics sur la vue texte.
        func connect(_ textView: WritingTextView) {
            let comments = editor.comments
            highlighter.commentMarks = { [weak self, weak comments] paragraph in
                guard let self, self.review == nil, let comments else { return [] }
                return comments.marks(in: paragraph)
            }
            highlighter.diffMarks = { [weak self] paragraph in self?.review?.marks(in: paragraph) ?? [] }
            highlighter.hiddenTitleLocation = editor.live.titleHeading
            highlighter.partLevel = editor.live.partLevel
            highlighter.firstHeadingLocation = editor.live.firstHeadingID
            editor.live.onPartLayout = { [weak self, weak textView] level, first, headings in
                guard let self, let textView, let storage = textView.textStorage else { return }
                self.highlighter.partLevel = level
                self.highlighter.firstHeadingLocation = first
                // Poème : pas de séparateurs de parties (les « titres » du sommaire sont les versets).
                guard self.loadedToken == self.editor.reloadToken, self.review == nil, !self.highlighter.poemMode else { return }
                textView.preservingScrollAnchor {
                    self.highlighter.rehighlight(headings.map { NSRange(location: $0, length: 0) }, in: storage)
                }
            }
            editor.live.onTitleHeading = { [weak self, weak textView] location in
                guard let self, let textView, let storage = textView.textStorage else { return }
                let old = self.highlighter.hiddenTitleLocation
                self.highlighter.hiddenTitleLocation = location
                guard self.loadedToken == self.editor.reloadToken else { return }
                textView.preservingScrollAnchor {
                    self.highlighter.rehighlight([old, location].compactMap { $0 }.map { NSRange(location: $0, length: 0) }, in: storage)
                }
            }
            comments.textProvider = { [weak textView] in textView?.textStorage?.mutableString ?? "" }
            comments.onMarksChanged = { [weak self, weak textView] ranges in
                guard let self, let textView, let storage = textView.textStorage, self.review == nil,
                      self.loadedToken == self.editor.reloadToken else { return }
                textView.preservingScrollAnchor { self.highlighter.rehighlight(ranges, in: storage) }
            }
            comments.onReveal = { [weak textView] range in textView?.scrollToShow(range.location) }
            editor.scrollHandler = { [weak textView] location, animated in
                textView?.scrollToReadingLine(location, animated: animated)
            }
            textView.onComment = { [weak self, weak textView] range in
                guard let self, let textView, self.review == nil, range.length > 0,
                      let text = textView.textStorage?.mutableString else { return }
                textView.hideBubble()
                self.editor.revealCommentsPanel()
                comments.startDraft(range: range, in: text)
            }
            textView.onTextClick = { [weak self] location in
                guard let self else { return }
                if let review = self.review {
                    if let i = review.change(at: location) { self.editor.selectChange(i) }
                } else if let id = comments.comment(at: location) {
                    self.editor.revealCommentsPanel()
                    comments.select(id, reveal: false)
                }
            }
            textView.onPinClick = { [weak self] id in
                self?.editor.revealCommentsPanel()
                comments.select(id, reveal: false)
            }
        }
        var loadedURL: URL?
        var isLoading = false
        var frameObserver: NSObjectProtocol?
        var scrollObserver: NSObjectProtocol?
        private var readingUpdateScheduled = false

        /// Défilement : met à jour la progression de lecture du sommaire, une fois par tour de boucle.
        func scrolled() {
            guard !readingUpdateScheduled else { return }
            readingUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readingUpdateScheduled = false
                // Le défilement met en page des fragments jusque-là estimés : le texte au-dessus peut changer
                // de hauteur. Curseur et filet sont recalculés sur la mise en page réelle.
                self.textView?.updateCaret(animated: false)
                guard self.review == nil, let location = self.textView?.readingLocation() else { return }
                self.editor.live.readingMoved(to: location)
            }
        }

        init(editor: EditorModel) { self.editor = editor }

        deinit {
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let textView = notification.object as? NSTextView else { return }
            editor.bodyDidChange(textView.string)
            if (textView as? WritingTextView)?.poemEditing == true { scheduleRenumber() }
            // Après la mise en page de la frappe : document court entièrement mis en page.
            if (textView.string as NSString).length < WritingTextView.fullLayoutLimit {
                DispatchQueue.main.async { [weak textView] in (textView as? WritingTextView)?.preservingScrollAnchor {} }
            }
        }

        private var renumberWork: DispatchWorkItem?

        /// Poème : les numéros des versets sont recalés peu après la frappe (avant l'enregistrement automatique).
        func scheduleRenumber() {
            renumberWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.review == nil, !self.isLoading else { return }
                self.textView?.renumberVerses()
            }
            renumberWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }

        /// Poème : le curseur ne s'arrête jamais dans un numéro masqué ni sur une ligne vide entre deux versets.
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                      toCharacterRange new: NSRange) -> NSRange {
            guard !isLoading, review == nil, new.length == 0, (textView as? WritingTextView)?.poemEditing == true else { return new }
            return NSRange(location: PoemCaret.adjust(new.location, from: old.location, in: textView.string as NSString), length: 0)
        }

        /// Chaque modification exacte du texte (frappe, collage, commande, annuler) : les commentaires suivent.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if !isLoading, review == nil, let replacement = replacementString {
                let length = (replacement as NSString).length
                editor.comments.textEdited(NSRange(location: affectedCharRange.location, length: length),
                                           delta: length - affectedCharRange.length)
            }
            return true
        }

        /// Pas de soulignement d'orthographe sur le texte masqué (marqueurs, nom d'image).
        func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
            guard value != 0, let storage = textView.textStorage, affectedCharRange.location < storage.length,
                  let font = storage.attribute(.font, at: affectedCharRange.location, effectiveRange: nil) as? NSFont,
                  font.pointSize < 1 else { return value }
            return 0
        }

        private var selectionUpdateScheduled = false

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, let storage = textView.textStorage else { return }
            // Comptes de la barre d'état : une fois par tour de boucle, pas à chaque mouvement de souris.
            if !selectionUpdateScheduled {
                selectionUpdateScheduled = true
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.selectionUpdateScheduled = false
                    self.editor.live.selectionChanged(textView.selectedRange(), in: textView.textStorage?.mutableString ?? "")
                }
            }
            guard !isLoading else { return }
            // Les marqueurs Markdown n'apparaissent que dans le paragraphe du curseur, et jamais pendant
            // une sélection (le texte ne doit pas bouger sous la souris).
            let selection = textView.selectedRange()
            // Remettre en forme un paragraphe situé plus haut invalide la mise en page jusqu'à la zone visible :
            // TextKit 2 replace alors le texte d'après des hauteurs estimées et la page « saute ». On garde donc
            // à l'écran le texte qui y était (ancre de défilement).
            let active = selection.length == 0 ? selection.location : nil
            if highlighter.paragraphChanges(active: active, focus: selection.location, in: storage) {
                (textView as? WritingTextView)?.preservingScrollAnchor {
                    highlighter.setActiveLocation(active, focus: selection.location, in: storage)
                }
            }
        }

        /// Image `![[nom]]` cherchée à côté du document, puis dans un éventuel sous-dossier du même nom.
        func image(named name: String) -> NSImage? {
            if let cached = imageCache[name] { return cached }
            guard let folder = editor.url?.deletingLastPathComponent() else { return nil }
            let file = (name.components(separatedBy: "|").first ?? name).trimmingCharacters(in: .whitespaces)
            for candidate in [folder.appendingPathComponent(file)] {
                if let image = NSImage(contentsOf: candidate) {
                    imageCache[name] = image
                    return image
                }
            }
            return nil
        }
    }
}
