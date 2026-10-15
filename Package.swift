// swift-tools-version: 5.10
// Licence : GPL-3.0-or-later (voir LICENSE). Polices de repli dans Resources/Polices : SIL Open Font License.
import PackageDescription

let package = Package(
    name: "Ecritoire",
    defaultLocalization: "fr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ecritoire", targets: ["Ecritoire"]),
        .executable(name: "importer-scrivener", targets: ["ImporterScrivener"]),
    ],
    targets: [
        // Logique sans interface : en-tête YAML, fichiers .order, opérations sur le classeur, surveillance du disque.
        .target(name: "EcritoireCore"),
        // Application SwiftUI + AppKit.
        .executableTarget(name: "Ecritoire", dependencies: ["EcritoireCore", "ScrivenerImport"]),
        // Import de projets Scrivener 3 (.scriv) : bibliothèque + outil en ligne de commande.
        .target(name: "ScrivenerImport", dependencies: ["EcritoireCore"]),
        .executableTarget(name: "ImporterScrivener", dependencies: ["ScrivenerImport"]),
        // Vérifications de la logique du classeur : `swift run EcritoireVerifs`.
        // (Pas de testTarget : sans Xcode, les macros de XCTest/Swift Testing ne sont pas disponibles.)
        .executableTarget(name: "EcritoireVerifs", dependencies: ["EcritoireCore"]),
    ]
)
