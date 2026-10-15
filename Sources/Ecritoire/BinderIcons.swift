import AppKit
import EcritoireCore

/// Catalogue d'icônes du classeur (repris des icônes de Scrivener, dessinées avec les SF Symbols).
/// L'identifiant est enregistré dans le fichier `.icones` du dossier parent.
enum BinderIcons {
    struct Entry {
        let id: String
        let label: String
        let symbol: String
        let color: NSColor
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let folderBlue = rgb(0x8DBEEB)
    static let documentGray = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.52, alpha: 1)
    }

    static let catalog: [Entry] = [
        Entry(id: "carnet-rouge", label: "Carnet rouge", symbol: "book.closed.fill", color: rgb(0xE5937D)),
        Entry(id: "carnet-orange", label: "Carnet orange", symbol: "book.closed.fill", color: rgb(0xEDAA6E)),
        Entry(id: "carnet-jaune", label: "Carnet jaune", symbol: "book.closed.fill", color: rgb(0xEFCD62)),
        Entry(id: "carnet-vert", label: "Carnet vert", symbol: "book.closed.fill", color: rgb(0x8CC57A)),
        Entry(id: "carnet-bleu", label: "Carnet bleu", symbol: "book.closed.fill", color: rgb(0x86B4E3)),
        Entry(id: "carnet-violet", label: "Carnet violet", symbol: "book.closed.fill", color: rgb(0x9467BD)),
        Entry(id: "carnet-rose", label: "Carnet rose", symbol: "book.closed.fill", color: rgb(0xE07AA0)),
        Entry(id: "carnet-brun", label: "Carnet brun", symbol: "book.closed.fill", color: rgb(0x9C6B45)),
        Entry(id: "carnet-noir", label: "Carnet noir", symbol: "book.closed.fill", color: rgb(0x3D3929)),
        Entry(id: "notes", label: "Bloc-notes", symbol: "note.text", color: rgb(0x8A877C)),
        Entry(id: "eprouvette", label: "Éprouvette", symbol: "testtube.2", color: rgb(0xB48BDB)),
        Entry(id: "crayon", label: "Crayon", symbol: "pencil", color: rgb(0xD9A441)),
        Entry(id: "carte", label: "Carte", symbol: "mappin.and.ellipse", color: rgb(0xD9776A)),
        Entry(id: "classeur", label: "Classeur à tiroirs", symbol: "cabinet.fill", color: rgb(0x9E9A90)),
        Entry(id: "calendrier", label: "Calendrier", symbol: "calendar", color: rgb(0xD9534F)),
        Entry(id: "liminaire", label: "Pages liminaires", symbol: "doc.on.doc", color: rgb(0x8A877C)),
        Entry(id: "pellicule", label: "Pellicule", symbol: "film.fill", color: rgb(0x5B5B66)),
        Entry(id: "spirale", label: "Carnet à spirale", symbol: "book.pages.fill", color: rgb(0x4A86C8)),
        Entry(id: "personnage", label: "Personnage", symbol: "person.crop.square.fill", color: rgb(0xE8954A)),
        Entry(id: "idee", label: "Idée", symbol: "lightbulb.fill", color: rgb(0xE6B83A)),
        Entry(id: "etoile", label: "Étoile", symbol: "star.fill", color: rgb(0xE6B83A)),
        Entry(id: "drapeau", label: "Drapeau", symbol: "flag.fill", color: rgb(0xD9534F)),
        Entry(id: "epingle", label: "Épingle", symbol: "pin.fill", color: rgb(0xD9534F)),
        Entry(id: "manuscrit", label: "Manuscrit", symbol: "text.book.closed.fill", color: rgb(0x7B5FBF)),
        Entry(id: "recherche", label: "Recherche", symbol: "magnifyingglass.circle.fill", color: rgb(0x4A86C8)),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })

    static func entry(_ id: String?) -> Entry? { id.flatMap { byID[$0] } }

    /// Symbole et couleur d'un élément du classeur.
    static func appearance(for node: BinderNode) -> (NSImage?, NSColor) {
        if let entry = entry(node.icon) {
            return (NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.label), entry.color)
        }
        if node.isFolder {
            return (NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Dossier"), folderBlue)
        }
        return (NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: "Document"), documentGray)
    }

    static func menuImage(_ entry: Entry) -> NSImage? {
        let config = NSImage.SymbolConfiguration(paletteColors: [entry.color])
        return NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.label)?.withSymbolConfiguration(config)
    }

    /// Première ligne du texte d'un document « Sans titre », pour l'afficher dans le classeur.
    static func preview(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 6000),
              let text = String(data: data, encoding: .utf8) ?? String(data: data.dropLast(3), encoding: .utf8) else { return nil }
        let body = MarkdownDocument.parse(text).body
        for raw in body.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("![[") || line.lowercased().hasPrefix("> [!") { continue }
            line = line.replacingOccurrences(of: #"^(#{1,6}\s+|>\s?|[-*+]\s+)"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\*\*|==|\\|<[^>]+>|\[\[|\]\]"#, with: "", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            return line.count > 70 ? String(line.prefix(70)) + "…" : line
        }
        return nil
    }

    static func isUntitled(_ node: BinderNode) -> Bool {
        guard !node.isFolder else { return false }
        let name = node.displayName.lowercased()
        return name.hasPrefix("sans titre") || name.hasPrefix("untitled")
    }
}
