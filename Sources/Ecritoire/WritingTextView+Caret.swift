import AppKit
import SwiftUI

/// Curseur vivant, bulle de sélection et sélection aimantée.
extension WritingTextView {
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Curseur

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let window else { return }
        wantsLayer = true
        // (Ré)attache les calques si la vue a changé de calque (déplacement dans la hiérarchie) :
        // l'état « affiché » repart de zéro, sinon le filet resterait invisible.
        if paragraphBar.superlayer !== layer {
            paragraphShown = false
            paragraphLocation = -1
            for l in [paragraphTint, paragraphBar] {
                l.removeFromSuperlayer()
                l.opacity = 0
                l.zPosition = 50
                layer?.addSublayer(l)
            }
            paragraphBar.cornerRadius = 1.5
            paragraphTint.cornerRadius = 6
        }
        if caretLayer.superlayer !== layer {
            caretLayer.removeFromSuperlayer()
            caretVisible = false
            insertionPointColor = .clear
            caretLayer.cornerRadius = 1.25
            caretLayer.zPosition = 100
            caretLayer.opacity = 0
            layer?.addSublayer(caretLayer)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCaret(animated: false) }
            })
        }
        updateCaret(animated: false)
    }

    /// Le curseur système n'est jamais dessiné : c'est caretLayer qui le remplace.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {}

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        updateCaret(animated: false)
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        updateCaret(animated: false)
        hideBubble()
        return ok
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateCaret(animated: true)
        if stillSelecting || selectedRange().length == 0 { hideBubble() } else { scheduleBubble() }
    }

    func updateCaret(animated: Bool, typing: Bool = false) {
        guard let window else { return }
        let selection = selectedRange()
        let show = selection.length == 0 && isEditable
            && (forceCaretForCapture || (window.isKeyWindow && window.firstResponder === self))
        updateParagraphIndicator(animated: animated)
        guard show else {
            if caretVisible {
                caretVisible = false
                caretLayer.removeAllAnimations()
                CATransaction.begin(); CATransaction.setDisableActions(true)
                caretLayer.opacity = 0
                CATransaction.commit()
            }
            return
        }
        let font = caretFont(at: selection.location)
        let width: CGFloat = max(2, (font.pointSize / 8).rounded())
        let height = ((font.ascender - font.descender) * 1.08).rounded()
        guard let (x, baseline) = caretPosition(at: selection.location) else { return }
        let frame = CGRect(x: x - width / 2, y: baseline - font.ascender * 1.04, width: width, height: height)

        CATransaction.begin()
        let glide = animated && caretVisible && !reduceMotion && abs(frame.midY - caretLayer.frame.midY) < 400
        if glide {
            CATransaction.setAnimationDuration(0.085)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            caretLayer.backgroundColor = Palette.accent.cgColor
        }
        caretLayer.frame = frame
        caretLayer.cornerRadius = width / 2
        CATransaction.commit()

        caretVisible = true
        restartBlink()
        if typing && !reduceMotion { bounceCaret() }
    }

    /// Met en avant le paragraphe du curseur : filet lavande qui glisse d'un paragraphe à l'autre, fond très léger.
    func updateParagraphIndicator(animated: Bool) {
        // Le filet et le fond sont désormais dessinés par les fragments de texte eux-mêmes (RichLayoutFragment.drawFocus).
        if paragraphShown || paragraphBar.opacity > 0 {
            paragraphShown = false
            paragraphBar.opacity = 0
            paragraphTint.opacity = 0
        }
        return
        let selection = selectedRange()
        // Visible tant qu'un document est ouvert : le filet suit le paragraphe du curseur (ou du début de la sélection)
        // et ne disparaît jamais de lui-même.
        let visible = isEditable
        func hide() {
            guard paragraphShown else { return }
            paragraphShown = false
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            paragraphBar.opacity = 0
            paragraphTint.opacity = 0
            CATransaction.commit()
        }
        guard visible else { hide(); return }
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let location = tcm.location(tcm.documentRange.location, offsetBy: min(selection.location, (string as NSString).length)) else { return }
        tlm.ensureLayout(for: NSTextRange(location: location))
        // Fragment pas encore disponible : on garde le filet où il est (pas de clignotement).
        guard let fragment = tlm.textLayoutFragment(for: location) else { return }
        let lines = fragment.textLineFragments
        guard let first = lines.first, let last = lines.last else { return }
        let paragraphStart = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
        let frame = fragment.layoutFragmentFrame
        let top = frame.minY + first.typographicBounds.minY + textContainerOrigin.y
        let bottom = frame.minY + last.typographicBounds.maxY + textContainerOrigin.y
        // Paragraphe vide ou masqué (séparateur) : pas d'indicateur.
        guard bottom - top > 6 else { hide(); return }
        let gutter = max(14, (textContainerInset.width) * 0.22)
        let barFrame = CGRect(x: textContainerOrigin.x - gutter, y: top + 3, width: 3, height: bottom - top - 6)
        let containerWidth = textContainer?.size.width ?? bounds.width
        let tintFrame = CGRect(x: textContainerOrigin.x - gutter * 0.6, y: top - 4,
                               width: containerWidth + gutter * 1.2, height: bottom - top + 8)
        CATransaction.begin()
        // Glissement seulement quand on change de paragraphe ; sinon (frappe, nouvelle ligne) mise à jour immédiate.
        let changed = paragraphStart != paragraphLocation
        paragraphLocation = paragraphStart
        let glide = animated && changed && paragraphShown && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if glide {
            CATransaction.setAnimationDuration(0.22)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            paragraphBar.backgroundColor = Palette.accent.withAlphaComponent(0.7).cgColor
            paragraphTint.backgroundColor = Palette.accent.withAlphaComponent(0.045).cgColor
        }
        paragraphBar.frame = barFrame
        paragraphTint.frame = tintFrame
        CATransaction.commit()
        if !paragraphShown || paragraphBar.opacity < 1 {
            paragraphShown = true
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            paragraphBar.opacity = 1
            paragraphTint.opacity = 1
            CATransaction.commit()
        }
    }

    /// Position exacte du point d'insertion (x, ligne de base), lue dans la mise en page TextKit 2
    /// après s'être assuré que le fragment est mis en page ; en coordonnées de la vue texte.
    func caretPosition(at location: Int) -> (CGFloat, CGFloat)? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let length = (string as NSString).length
        let clamped = min(max(location, 0), length)
        if let textLocation = tcm.location(tcm.documentRange.location, offsetBy: clamped) {
            // Surtout pas d'ensureLayout ici : sur un long document, il place le fragment d'après des hauteurs
            // estimées, différemment des fragments réellement dessinés dans la zone visible — d'où un décalage.
            if let fragment = tlm.textLayoutFragment(for: textLocation) {
                let paragraphStart = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
                let offset = clamped - paragraphStart
                let lines = fragment.textLineFragments
                if let line = lines.last(where: { $0.characterRange.location <= offset }) ?? lines.first {
                    let frame = fragment.layoutFragmentFrame
                    let x = frame.minX + line.typographicBounds.minX + line.locationForCharacter(at: min(offset, NSMaxRange(line.characterRange))).x
                    let baseline = frame.minY + line.typographicBounds.minY + line.glyphOrigin.y
                    return (x + textContainerOrigin.x, baseline + textContainerOrigin.y)
                }
            }
        }
        // Repli (fin de document vide…) : rectangle donné par le système.
        guard let window else { return nil }
        let screenRect = firstRect(forCharacterRange: NSRange(location: clamped, length: 0), actualRange: nil)
        guard screenRect.height > 0 else { return nil }
        let rect = convert(window.convertFromScreen(screenRect), from: nil)
        let font = caretFont(at: clamped)
        return (rect.minX, rect.maxY + font.descender)
    }

    private func caretFont(at location: Int) -> NSFont {
        guard let storage = textStorage, storage.length > 0 else {
            return typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: 17)
        }
        for candidate in [location - 1, location] where candidate >= 0 && candidate < storage.length {
            if let font = storage.attribute(.font, at: candidate, effectiveRange: nil) as? NSFont, font.pointSize >= 4 {
                return font
            }
        }
        return typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: 17)
    }

    /// Respiration douce : le curseur reste plein après un mouvement, puis s'estompe et revient.
    private func restartBlink() {
        caretLayer.removeAnimation(forKey: "respiration")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        caretLayer.opacity = 1
        CATransaction.commit()
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.12
        breathe.duration = 0.55
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.beginTime = caretLayer.convertTime(CACurrentMediaTime(), from: nil) + 0.6
        breathe.fillMode = .backwards
        caretLayer.add(breathe, forKey: "respiration")
    }

    /// Petit rebond vertical à chaque frappe.
    private func bounceCaret() {
        let spring = CASpringAnimation(keyPath: "transform.scale.y")
        spring.fromValue = 1.22
        spring.toValue = 1
        spring.mass = 0.5
        spring.stiffness = 420
        spring.damping = 11
        spring.duration = spring.settlingDuration
        caretLayer.add(spring, forKey: "rebond")
    }

    /// Après chaque mise en page du texte visible (y compris le remplacement des hauteurs estimées),
    /// le curseur est recalé sur la mise en page réelle.
    override func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(controller)
        guard !Self.inLayoutCallback else { return }
        Self.inLayoutCallback = true
        updateCaret(animated: false)
        Self.inLayoutCallback = false
    }

    nonisolated(unsafe) static var inLayoutCallback = false

    // MARK: Bulle de sélection

    func scheduleBubble() {
        bubbleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showBubble() }
        bubbleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    func hideBubble() {
        bubbleWork?.cancel()
        guard let bubble else { return }
        self.bubble = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            bubble.animator().alphaValue = 0
        }, completionHandler: { bubble.removeFromSuperview() })
    }

    private func showBubble() {
        let selection = selectedRange()
        guard selection.length > 0, let window, let makeBubble else { return }
        bubble?.removeFromSuperview()
        let view = makeBubble()
        let size = view.fittingSize
        let first = convert(window.convertFromScreen(firstRect(forCharacterRange: NSRange(location: selection.location, length: 0), actualRange: nil)), from: nil)
        let visible = visibleRect
        var y = first.minY - size.height - 8
        if y < visible.minY + 4 {
            let last = convert(window.convertFromScreen(firstRect(forCharacterRange: NSRange(location: NSMaxRange(selection), length: 0), actualRange: nil)), from: nil)
            y = last.maxY + 8
        }
        let x = min(max(first.minX - 12, visible.minX + 8), visible.maxX - size.width - 8)
        let target = NSRect(x: x, y: y, width: size.width, height: size.height)
        view.frame = target.offsetBy(dx: 0, dy: reduceMotion ? 0 : 6)
        view.alphaValue = 0
        addSubview(view)
        bubble = view
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            view.animator().alphaValue = 1
            view.animator().frame = target
        }
    }

    // MARK: Sélection aimantée

    override func mouseDown(with event: NSEvent) {
        hideBubble()
        let point = convert(event.locationInWindow, from: nil)
        // Clic dans la marge gauche : sélectionne le paragraphe entier.
        if point.x < textContainerOrigin.x - 6, event.clickCount == 1, let tlm = textLayoutManager, let tcm = tlm.textContentManager,
           let fragment = tlm.textLayoutFragment(for: CGPoint(x: 1, y: point.y - textContainerOrigin.y)) {
            let start = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
            var range = (string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
            if range.length > 0, (string as NSString).character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }
            window?.makeFirstResponder(self)
            setSelectedRange(range)
            return
        }
        // Pastille de commentaire dans la marge droite ?
        let right = textContainerOrigin.x + (textContainer?.size.width ?? bounds.width)
        if point.x > right + 6, event.clickCount == 1, let id = pinID(at: point) {
            onPinClick?(id)
            return
        }
        isDraggingSelection = true
        super.mouseDown(with: event)
        isDraggingSelection = false
        // Fin du glisser : on montre la bulle si du texte est sélectionné.
        if selectedRange().length > 0 {
            scheduleBubble()
        } else if event.clickCount == 1 {
            onTextClick?(selectedRange().location)
        }
    }

    /// Commentaire dont la pastille est à cette hauteur.
    private func pinID(at point: NSPoint) -> UUID? {
        guard let tlm = textLayoutManager else { return nil }
        let y = point.y - textContainerOrigin.y
        guard let fragment = tlm.textLayoutFragment(for: CGPoint(x: 1, y: y)),
              let paragraph = fragment.textElement as? NSTextParagraph else { return nil }
        let string = paragraph.attributedString
        var best: (UUID, CGFloat)? = nil
        string.enumerateAttribute(.ecritoireCommentPin, in: NSRange(location: 0, length: string.length)) { value, run, _ in
            guard let mark = value as? CommentMark, let id = mark.id else { return }
            let line = fragment.textLineFragments.first { NSLocationInRange(run.location, $0.characterRange) }
            let lineMid = fragment.layoutFragmentFrame.minY + (line?.typographicBounds.midY ?? 0)
            let distance = abs(lineMid - y)
            if best == nil || distance < best!.1 { best = (id, distance) }
        }
        return best.flatMap { $0.1 < 40 ? $0.0 : nil }
    }

    override func selectionRange(forProposedRange proposed: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        let base = super.selectionRange(forProposedRange: proposed, granularity: granularity)
        guard isDraggingSelection, granularity == .selectByCharacter, proposed.length > 1,
              UserDefaults.standard.object(forKey: "selectionAimantee") as? Bool ?? true else { return base }
        let text = string as NSString
        let startPara = text.paragraphRange(for: NSRange(location: proposed.location, length: 0))
        let endPara = text.paragraphRange(for: NSRange(location: max(proposed.location, NSMaxRange(proposed) - 1), length: 0))
        if startPara.location != endPara.location {
            // Au-delà d'une fin de paragraphe : paragraphes entiers (sans le dernier retour à la ligne).
            var union = NSUnionRange(startPara, endPara)
            if union.length > 0, text.character(at: NSMaxRange(union) - 1) == 0x0A { union.length -= 1 }
            return union
        }
        return super.selectionRange(forProposedRange: proposed, granularity: .selectByWord)
    }
}

/// Bulle flottante au-dessus de la sélection.
struct SelectionBubble: View {
    let perform: (EditorCommand) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HighlightColor.allCases) { color in
                HighlightDot(color: color) { perform(.highlight(color)) }
            }
            ToolIcon(systemImage: "eraser", help: "Retirer le surlignage") { perform(.eraseHighlight) }
            BubbleDivider()
            ToolIcon(systemImage: "bold", help: "Gras (⌘B)") { perform(.bold) }
            ToolIcon(systemImage: "italic", help: "Italique (⌘I)") { perform(.italic) }
            ToolIcon(systemImage: "link", help: "Lien interne [[…]] (⌘K)") { perform(.wikiLink) }
            BubbleDivider()
            ToolIcon(systemImage: "text.bubble", help: "Commenter (⌥⌘M)") { perform(.comment) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(Palette.page), in: RoundedRectangle(cornerRadius: UI.radius))
        .overlay(RoundedRectangle(cornerRadius: UI.radius).stroke(Color(Palette.border)))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        .padding(10) // place pour l'ombre
    }
}

struct BubbleDivider: View {
    var body: some View {
        Rectangle().fill(Color(Palette.border)).frame(width: 1, height: 18).padding(.horizontal, 4)
    }
}

/// Pastille de couleur de surligneur, qui grossit au survol.
struct HighlightDot: View {
    let color: HighlightColor
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(color.nsColor))
                .overlay(Circle().stroke(Color.black.opacity(0.12)))
                .frame(width: 13, height: 13)
                .scaleEffect(hover.isOn ? 1.2 : 1)
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help("Surligner en \(color.rawValue)" + (color == .jaune ? " (⇧⌘H)" : ""))
        .onHover { on in withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { hover.isOn = on } }
    }
}

/// Bouton d'outil : fond doux au survol, léger enfoncement au clic.
struct ToolIcon: View {
    let systemImage: String
    let help: String
    var isActive = false
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(isActive ? Color(Palette.text) : UI.icon)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color(Palette.selection).opacity(isActive ? 1 : (hover.isOn ? 0.7 : 0))))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .onHover { on in withAnimation(.easeOut(duration: 0.12)) { hover.isOn = on } }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

// MARK: - Survol des paragraphes et pointeur « I » élégant

extension WritingTextView {
    /// Pointeur en I fin à empattements courbes, assez grand (le comportement reste celui du système).
    static let elegantIBeam: NSCursor = {
        let size = NSSize(width: 22, height: 40)
        let image = NSImage(size: size, flipped: false) { rect in
            let midX = rect.midX, top = rect.maxY - 2.5, bottom = rect.minY + 2.5, arm: CGFloat = 6.5, drop: CGFloat = 4.5
            func shape() -> NSBezierPath {
                let p = NSBezierPath()
                // Fût
                p.move(to: NSPoint(x: midX, y: top - drop)); p.line(to: NSPoint(x: midX, y: bottom + drop))
                // Empattements courbes (haut et bas) qui se fondent dans le fût, comme des accolades couchées
                p.move(to: NSPoint(x: midX - arm, y: top))
                p.curve(to: NSPoint(x: midX, y: top - drop), controlPoint1: NSPoint(x: midX - 2, y: top), controlPoint2: NSPoint(x: midX, y: top - 1.2))
                p.curve(to: NSPoint(x: midX + arm, y: top), controlPoint1: NSPoint(x: midX, y: top - 1.2), controlPoint2: NSPoint(x: midX + 2, y: top))
                p.move(to: NSPoint(x: midX - arm, y: bottom))
                p.curve(to: NSPoint(x: midX, y: bottom + drop), controlPoint1: NSPoint(x: midX - 2, y: bottom), controlPoint2: NSPoint(x: midX, y: bottom + 1.2))
                p.curve(to: NSPoint(x: midX + arm, y: bottom), controlPoint1: NSPoint(x: midX, y: bottom + 1.2), controlPoint2: NSPoint(x: midX + 2, y: bottom))
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                return p
            }
            // Liseré clair pour rester lisible sur fond sombre, puis trait gris.
            let halo = shape(); halo.lineWidth = 3.6; NSColor.white.withAlphaComponent(0.9).setStroke(); halo.stroke()
            let stroke = shape(); stroke.lineWidth = 1.7; NSColor(white: 0.42, alpha: 1).setStroke(); stroke.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: Self.elegantIBeam)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredParagraph(nil)
    }

    func updateHover(at point: NSPoint) {
        guard let tlm = textLayoutManager else { return }
        let local = CGPoint(x: 1, y: point.y - textContainerOrigin.y)
        let width = textContainer?.size.width ?? bounds.width
        guard point.x > textContainerOrigin.x - 40, point.x < textContainerOrigin.x + width + 40,
              let fragment = tlm.textLayoutFragment(for: local), let last = fragment.textLineFragments.last,
              local.y <= fragment.layoutFragmentFrame.minY + last.typographicBounds.maxY + 6 else {
            setHoveredParagraph(nil)
            return
        }
        setHoveredParagraph(fragment.rangeInElement)
    }

    /// Change le paragraphe survolé : seuls les deux fragments concernés sont redessinés (aucune remise en page).
    private func setHoveredParagraph(_ range: NSTextRange?) {
        if let range, let current = HoverParagraph.range, current.location.compare(range.location) == .orderedSame { return }
        if range == nil && HoverParagraph.range == nil { return }
        let old = HoverParagraph.range
        HoverParagraph.range = range
        HoverParagraph.fontSize = (typingAttributes[.font] as? NSFont)?.pointSize ?? 19
        guard let tlm = textLayoutManager else { return }
        for r in [old, range].compactMap({ $0 }) {
            tlm.invalidateRenderingAttributes(for: r)
            tlm.addRenderingAttribute(.ecritoireHover, value: true, for: r)
            tlm.removeRenderingAttribute(.ecritoireHover, for: r)
        }
    }
}
