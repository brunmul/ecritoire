import AppKit

/// Polices libres de repli (licence SIL Open Font License), livrées dans `Resources/Polices` :
/// Libre Bodoni (texte, titres) et Hanken Grotesk (sous-titres, intro, citations). Elles servent quand
/// Walbaum n'est pas installée sur le Mac ; Walbaum, police payante, n'est jamais distribuée avec l'app.
enum FreeFonts {
    /// `ECRITOIRE_SANS_WALBAUM=1` : ignore Walbaum même installée (pour vérifier le rendu de repli).
    static let ignoreWalbaum = ProcessInfo.processInfo.environment["ECRITOIRE_SANS_WALBAUM"] != nil

    /// Dossier des polices : dans l'app (`Contents/Resources/Polices`), sinon dans les sources (`swift run`).
    static var folder: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Polices"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Polices"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var registered = false

    /// Rend les polices disponibles pour ce processus seulement (rien n'est installé sur le Mac).
    static func register() {
        guard !registered, let folder else { return }
        registered = true
        let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    static func font(_ family: EditorTheme.Family, size: CGFloat, bold: Bool, italic: Bool) -> NSFont? {
        register()
        let name = family == .serif || family == .display ? "Libre Bodoni" : "Hanken Grotesk"
        var traits: NSFontTraitMask = []
        if bold || family == .groteskBlack { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        // Graisse NSFontManager (0 à 15) : 5 normal, 9 gras, 13 noir.
        let weight = family == .groteskBlack ? 13 : bold ? 9 : 5
        return NSFontManager.shared.font(withFamily: name, traits: traits, weight: weight, size: size)
    }
}
