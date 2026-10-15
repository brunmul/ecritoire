import AppKit
import Sparkle

/// Mises à jour automatiques (Sparkle) : vérification une fois par jour, téléchargement et installation en
/// arrière-plan, versions signées en EdDSA et publiées sur GitHub (voir scripts/publier-version.sh).
/// Inactif hors de l'app empaquetée (`swift run`, vérifications), faute de flux dans l'Info.plist.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()
    private let controller: SPUStandardUpdaterController?

    private init() {
        let probe = CommandLine.arguments.contains { $0.hasPrefix("--") }
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil && !probe {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            controller = nil
        }
    }

    var available: Bool { controller != nil }

    /// Menu « Rechercher les mises à jour… ».
    func check() { controller?.checkForUpdates(nil) }
}
