import AppKit
import SwiftUI

/// Palette de l'interface, dans l'esprit de Claude : crèmes chauds, accent lavande foncé, mode sombre chaud.
/// La page d'écriture elle-même garde son blanc (voir PageClipView).
enum Palette {
    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(dark) : hex(light)
        }
    }

    /// Fond général (barre d'outils, barre d'état, inspecteur).
    static let background = dynamic(0xFAF9F5, 0x262624)
    /// Barre latérale du classeur.
    static let sidebar = dynamic(0xF0EEE6, 0x1F1E1D)
    /// Panneaux latéraux (classeur, sommaire, commentaires) : lavande très clair, comme Scrivener.
    static let panelLavender = dynamic(0xF6F2FB, 0x26232B)
    /// Second panneau (sommaire).
    static let panel = dynamic(0xF5F4EE, 0x232321)
    /// « Bureau » autour de la page.
    static let desk = dynamic(0xEFECF3, 0x1D1C20)
    /// Barre de la fenêtre : claire.
    static let header = dynamic(0xFCFBFD, 0x2A2830)
    /// Page d'écriture.
    static let page = dynamic(0xFFFFFF, 0x2B2A27)
    static let border = dynamic(0xE3DEEA, 0x3A3740)
    /// Surfaces flottantes (bulle de sélection, barre d'édition).
    static let elevated = dynamic(0xFFFFFF, 0x3A3936)
    static let text = dynamic(0x3D3929, 0xE8E6DC)
    static let secondaryText = dynamic(0x7A766A, 0xA19E94)
    /// Accent lavande foncé, accordé au fond des panneaux (curseur, sélection, index, commentaires…).
    static let accent = dynamic(0x7B5FBF, 0xA68FE0)
    static let accentStrong = dynamic(0x6A4FB0, 0xB8A4EA)
    /// Fond de sélection (classeur, sommaire, cartes) : lavande clair.
    static let selection = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? hex(0xA68FE0).withAlphaComponent(0.24) : hex(0xE9E2F7)
    }

    /// Sélection de texte : jaune surligneur.
    static let textSelection = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.84, blue: 0.25, alpha: 0.32) : NSColor(srgbRed: 1, green: 0.85, blue: 0.25, alpha: 0.45)
    }

    /// Titres d'interface en serif.
    static func serif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if !FreeFonts.ignoreWalbaum {
            if NSFont(name: "Walbaum10XLPro-Bold", size: size) != nil && weight != .regular {
                return .custom("Walbaum10XLPro-Bold", size: size)
            }
            if NSFont(name: "Walbaum10XLPro", size: size) != nil { return .custom("Walbaum10XLPro", size: size) }
        }
        if let font = FreeFonts.font(.serif, size: size, bold: weight != .regular, italic: false) { return Font(font) }
        return .system(size: size, weight: weight, design: .serif)
    }
}

/// Langage d'interface commun, calé sur le classeur (volet de gauche) : police système 13 pt,
/// lignes de 22 pt, barres de 30 pt, fond crème du classeur, filets fins, icônes grises ou pastel.
enum UI {
    static let font = Font.system(size: 13)
    static let fontBold = Font.system(size: 13, weight: .semibold)
    static let small = Font.system(size: 11.5)
    static let barHeight: CGFloat = 30
    static let radius: CGFloat = 7
    static var icon: Color { Color(nsColor: BinderIcons.documentGray) }
}

/// Barre du bas d'un panneau latéral : même hauteur et même filet que celle du classeur.
struct PanelFooter<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 6) { content }
            .font(UI.small)
            .foregroundStyle(Color(Palette.secondaryText))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: UI.barHeight)
            .background(Color(Palette.panelLavender))
            .overlay(alignment: .top) { Hairline() }
    }
}

/// Filet de séparation (1 pt) en haut ou en bas d'une barre.
struct Hairline: View {
    var body: some View { Rectangle().fill(Color(Palette.border)).frame(height: 1) }
}

extension Color {
    init(_ nsColor: NSColor) { self.init(nsColor: nsColor) }
}

/// Ligne de liste à sélection arrondie et teintée, au lieu du bleu système.
final class SoftRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 8, dy: 1)
        Palette.selection.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }

    /// Garde le texte sombre sur la sélection claire.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
