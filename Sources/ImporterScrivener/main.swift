import Foundation
import ScrivenerImport

// Usage : importer-scrivener <projet.scriv>… [--vers <dossier>]
// Par défaut, les classeurs sont créés dans ~/Documents/Classeurs. Les projets d'origine ne sont pas modifiés.
var args = Array(CommandLine.arguments.dropFirst())
var destination = ScrivenerImporter.defaultDestination()
if let i = args.firstIndex(of: "--vers"), i + 1 < args.count {
    destination = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
    args.removeSubrange(i...(i + 1))
}
// importer-scrivener --icones <projet.scriv> <classeur> : reporte seulement les icônes sur un classeur existant.
if let i = args.firstIndex(of: "--icones"), i + 2 < args.count {
    let project = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
    let classeur = URL(fileURLWithPath: (args[i + 2] as NSString).expandingTildeInPath)
    do {
        let n = try ScrivenerImporter.applyIcons(from: project, to: classeur)
        print("✓ \(n) icônes reportées sur \(classeur.lastPathComponent)")
        exit(0)
    } catch {
        print("✗ \(error.localizedDescription)")
        exit(1)
    }
}
guard !args.isEmpty else {
    print("Usage : importer-scrivener <projet.scriv>… [--vers <dossier>]")
    exit(2)
}
var failed = false
for path in args {
    let project = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    do {
        let importer = try ScrivenerImporter(project: project, destinationFolder: destination)
        let start = Date()
        let report = try importer.run()
        print("✓ \(project.lastPathComponent) → \(report.destination.path)")
        print("  \(report.documents) documents, \(report.folders) dossiers, \(report.files) images/fichiers, \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        for warning in report.warnings { print("  ⚠︎ \(warning)") }
    } catch {
        failed = true
        print("✗ \(project.lastPathComponent) : \(error.localizedDescription)")
    }
}
exit(failed ? 1 : 0)
