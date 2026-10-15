import Foundation
import EcritoireCore
import PDFKit

struct FrontmatterTests {
    func parseAndSerializeRoundTrip() {
        let text = """
        ---
        title: "Chapitre \\"un\\""
        synopsis: L'arrivée au village
        status: en cours
        publish: true
        tags: [roman, brouillon]
        aliases:
          - Ch1
        ---

        # Le village

        Il pleuvait.
        """
        let doc = MarkdownDocument.parse(text)
        expect(doc.title == "Chapitre \"un\"")
        expect(doc.synopsis == "L'arrivée au village")
        expect(doc.status == "en cours")
        expect(doc.publish)
        expect(doc.extraLines == ["tags: [roman, brouillon]", "aliases:", "  - Ch1"])
        expect(doc.body == "# Le village\n\nIl pleuvait.")

        let again = MarkdownDocument.parse(doc.serialized())
        expect(again == doc)
    }

    func documentWithoutFrontmatter() {
        let doc = MarkdownDocument.parse("Juste du texte.\n", defaultTitle: "Note")
        expect(doc.title == "Note")
        expect(doc.body == "Juste du texte.\n")
        expect(doc.serialized().hasPrefix("---\ntitle: \"Note\"\n"))
    }

    func wordCount() {
        expect(WordCounter.count("") == 0)
        expect(WordCounter.count("L'arbre — haut de 12 mètres.\n\n# Titre") == 6)
    }
}

final class BinderTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ecritoire-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func names(_ folder: URL) -> [String] { Binder.orderedEntries(in: folder).map(\.lastPathComponent) }

    func manualOrderAndCreation() throws {
        let b = try Binder.createDocument(in: root, named: "B")
        try Binder.createDocument(in: root, named: "A", at: 0)
        try Binder.createFolder(in: root, named: "Partie 1", at: 1)
        expect(names(root) == ["A.md", "Partie 1", "B.md"])
        expect(Binder.readOrder(in: root) == ["A.md", "Partie 1", "B.md"])

        // Un fichier créé par un autre outil apparaît à la fin.
        try "x".write(to: root.appendingPathComponent("0-externe.md"), atomically: true, encoding: .utf8)
        expect(names(root) == ["A.md", "Partie 1", "B.md", "0-externe.md"])

        // Les fichiers non .md et cachés sont ignorés.
        try "x".write(to: root.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)
        expect(!names(root).contains("image.png"))
        expect(!names(root).contains(".order"))

        let doc = MarkdownDocument.parse(try String(contentsOf: b, encoding: .utf8))
        expect(doc.title == "B")
    }

    func reorderWithinFolder() throws {
        for n in ["A", "B", "C", "D"] { try Binder.createDocument(in: root, named: n) }
        // Glisser A entre C et D (index 3 dans l'affichage d'origine).
        try Binder.move(root.appendingPathComponent("A.md"), into: root, at: 3)
        expect(names(root) == ["B.md", "C.md", "A.md", "D.md"])
        // Glisser D en tête.
        try Binder.move(root.appendingPathComponent("D.md"), into: root, at: 0)
        expect(names(root) == ["D.md", "B.md", "C.md", "A.md"])
        // Sans index : à la fin.
        try Binder.move(root.appendingPathComponent("D.md"), into: root, at: nil)
        expect(names(root) == ["B.md", "C.md", "A.md", "D.md"])
    }

    func moveBetweenFoldersAndRename() throws {
        let folder = try Binder.createFolder(in: root, named: "Partie")
        try Binder.createDocument(in: folder, named: "X")
        let a = try Binder.createDocument(in: root, named: "A")
        let moved = try Binder.move(a, into: folder, at: 0)
        expect(moved.path == folder.appendingPathComponent("A.md").path)
        expect(names(folder) == ["A.md", "X.md"])
        expect(names(root) == ["Partie"])

        let renamed = try Binder.rename(moved, to: "Avant-propos")
        expect(renamed.lastPathComponent == "Avant-propos.md")
        expect(names(folder) == ["Avant-propos.md", "X.md"])

        let renamedFolder = try Binder.rename(folder, to: "Première partie")
        expect(names(renamedFolder) == ["Avant-propos.md", "X.md"])
        expectThrows { try Binder.move(renamedFolder, into: renamedFolder, at: nil) }
        expectThrows { try Binder.rename(renamedFolder.appendingPathComponent("X.md"), to: "Avant-propos") }
    }

    func treeLoading() throws {
        let folder = try Binder.createFolder(in: root, named: "Partie")
        try Binder.createDocument(in: folder, named: "Ch1")
        try Binder.createDocument(in: root, named: "Notes")
        let tree = Binder.loadTree(at: root)
        expect(tree.children.map(\.displayName) == ["Partie", "Notes"])
        expect(tree.children[0].children.first?.displayName == "Ch1")
        expect(tree.children[0].children.first?.parent === tree.children[0])
    }
}

// MARK: - Exécution

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("✗ \(file):\(line) \(message)")
    }
}

func expectThrows(file: StaticString = #file, line: UInt = #line, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("✗ \(file):\(line) une erreur était attendue")
    } catch {}
}

func run(_ name: String, _ body: () throws -> Void) {
    let before = failures
    do { try body() } catch {
        failures += 1
        print("✗ \(name) : erreur \(error)")
    }
    print(failures == before ? "✓ \(name)" : "✗ \(name)")
}

func watcherDetectsExternalWrite() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ecritoire-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("doc.md")
    var seen = false
    let watcher = FileWatcher(root: root, latency: 0.05) { paths in
        if paths.contains(where: { $0.hasSuffix("/doc.md") }) { seen = true }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    try "bonjour".write(to: file, atomically: true, encoding: .utf8)
    let deadline = Date().addingTimeInterval(4)
    while !seen && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    expect(seen, "aucun événement FSEvents reçu")
    watcher.stop()
}

func diffTests() {
    let base = "Il pleuvait depuis trois jours.\nÉlise ferma la porte.\n\nLa gare était vide.\n"
    let current = "Il pleuvait depuis cinq jours.\nÉlise ferma la porte.\n\nUn paragraphe ajouté.\n\nLa gare était vide.\n"
    let hunks = TextDiff.hunks(from: base, to: current)
    expect(hunks.count == 2, "2 modifications attendues, \(hunks.count) trouvées : \(hunks)")
    expect(hunks.first?.deleted == "trois" && hunks.first?.inserted == "cinq", "remplacement au mot près")
    expect(hunks.last?.deleted == "" && hunks.last?.inserted.trimmingCharacters(in: .newlines) == "Un paragraphe ajouté.", "paragraphe ajouté")
    // Tout accepter ou tout refuser redonne l'une ou l'autre version.
    var b = base
    for h in hunks.reversed() { b = TextDiff.accept(h, base: b) }
    expect(b == current, "accepter tout")
    var c = current
    for h in hunks.reversed() { c = TextDiff.reject(h, current: c) }
    expect(c == base, "refuser tout")
    expect(TextDiff.hunks(from: "abc", to: "abc").isEmpty, "aucune différence")
}

func anchorTests() {
    let text = "Le chat dort. Le chat mange. Le chien aboie." as NSString
    let second = text.range(of: "Le chat mange")
    let (p, s) = CommentAnchor.context(of: NSRange(location: second.location, length: 7), in: text)
    let comment = DocumentComment(quote: "Le chat", prefix: p, suffix: s, text: "Préciser")
    expect(CommentAnchor.locate(comment, in: text) == NSRange(location: second.location, length: 7), "seconde occurrence retrouvée par le contexte")
    let edited = ("Préambule. " + (text as String)) as NSString
    expect(CommentAnchor.locate(comment, in: edited)?.location == second.location + 11, "ancrage après un ajout en tête")
    let gone = DocumentComment(quote: "introuvable", prefix: "", suffix: "", text: "x")
    expect(CommentAnchor.locate(gone, in: text) == nil, "passage disparu")
}

func sidecarTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ecritoire-sidecar-\(UUID().uuidString)")
    let doc = try Binder.createDocument(in: try Binder.createFolder(in: { try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root }(), named: "Partie"), named: "Ch1")
    var c = DocumentComment(quote: "a", prefix: "", suffix: "", text: "note")
    c.replies.append(.init(text: "réponse"))
    try Sidecar.saveComments([c], for: doc, in: root)
    expect(Sidecar.loadComments(for: doc, in: root) == [c], "commentaires relus à l'identique")
    expect(!Binder.loadTree(at: root).allDescendants.contains { $0.url.lastPathComponent == ".ecritoire" }, ".ecritoire caché du classeur")
    let moved = try Binder.rename(doc.deletingLastPathComponent(), to: "Première partie").appendingPathComponent("Ch1.md")
    Sidecar.relocate(from: doc, to: moved, in: root)
    Sidecar.relocate(from: doc.deletingLastPathComponent(), to: moved.deletingLastPathComponent(), in: root)
    expect(Sidecar.loadComments(for: moved, in: root).count == 1, "les commentaires suivent le renommage du dossier")
}

func poemTests() throws {
    let header = "# Titre\n\nRévision 1. Note qui cite [3] sans être un verset.\n\n---\n\n"
    // Victor Hugo, « Demain, dès l’aube » (Les Contemplations, 1856), domaine public.
    let text = header + "[1] Demain, dès l’aube, à l’heure où blanchit la campagne,\n\n[2] Je partirai. Vois-tu, je sais que tu m’attends.\n\n"
        + "[3] J’irai par la forêt, j’irai par la montagne.\n\n[4] Je ne puis demeurer loin de toi plus longtemps.\n"
    expect(Poem.isPoem(text), "format des versets reconnu")
    expect(!Poem.isPoem("Un paragraphe.\n\n# Titre\n"), "prose non reconnue comme poème")
    expect(!Poem.isPoem("[1](https://example.org) Note.\n\n[2](https://example.org) Autre note.\n"), "renvois de note [n](…) : pas un poème")
    let verses = Poem.verses(in: text)
    expect(verses.count == 4, "4 versets, \(verses.count) trouvés")
    expect(verses.first?.text == "Demain, dès l’aube, à l’heure où blanchit la campagne,", "texte du verset 1 sans marqueur")
    expect(Poem.renumberEdits(text).isEmpty, "texte déjà bien numéroté : aucune modification")
    let ns = text as NSString
    let v2 = ns.range(of: "Je partirai")
    expect(Poem.reference(for: NSRange(location: v2.location, length: 10), in: text) == "v. 2", "référence v. 2")
    let from = ns.range(of: "Je partirai"), to = ns.range(of: "j’irai par la montagne")
    expect(Poem.reference(for: NSRange(location: from.location, length: NSMaxRange(to) - from.location), in: text) == "v. 2–3", "référence v. 2–3")
    expect(Poem.reference(for: NSRange(location: 3, length: 4), in: text) == nil, "pas de référence dans l'en-tête")
    // Insertion d'un verset (Retour sans marqueur), suppression, fusion : numéros recalés.
    let poem = header + "[1] Un.\n\n[2] Deux.\n\n[3] Trois.\n\n[4] Quatre.\n"
    let inserted = poem.replacingOccurrences(of: "[1] Un.\n", with: "[1] Un.\nNouveau.\n")
    expect(Poem.renumbered(inserted) == header + "[1] Un.\n\n[2] Nouveau.\n\n[3] Deux.\n\n[4] Trois.\n\n[5] Quatre.\n", "insertion renumérotée : \(Poem.renumbered(inserted))")
    let deleted = poem.replacingOccurrences(of: "[2] Deux.\n\n", with: "")
    expect(Poem.renumbered(deleted) == header + "[1] Un.\n\n[2] Trois.\n\n[3] Quatre.\n", "suppression renumérotée")
    let merged = poem.replacingOccurrences(of: "Deux.\n\n[3] ", with: "Deux.[3] ")
    expect(Poem.renumbered(merged) == header + "[1] Un.\n\n[2] Deux. Trois.\n\n[3] Quatre.\n", "fusion : marqueur intérieur retiré : \(Poem.renumbered(merged))")
    let swapped = poem.replacingOccurrences(of: "[3] Trois.", with: "[9] Trois.")
    expect(Poem.renumbered(swapped) == poem, "numéro faux recalé")
    expect(Poem.renumbered(poem) == poem && Poem.renumbered("Prose [3] simple.\n") == "Prose [3] simple.\n", "idempotent, prose intacte")
    expect(Poem.headerEnd(in: poem as NSString) == (header as NSString).length - 1, "fin de l'en-tête juste après la ligne ---")
    // Affichage mémorisé dans .ecritoire, pas dans le fichier.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ecritoire-poeme-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let doc = root.appendingPathComponent("p.md")
    try poem.write(to: doc, atomically: true, encoding: .utf8)
    try Sidecar.setDisplay(.prose, for: doc, in: root)
    expect(Sidecar.display(for: doc, in: root) == .prose, "affichage mémorisé")
    expect((try? String(contentsOf: doc, encoding: .utf8)) == poem, "le fichier n'est pas touché")
}

func searchTests() throws {
    func f(_ t: String) -> String { String(decoding: SearchFold.query(t), as: UTF8.self) }
    expect(f("Élise ÉTÉ") == "elise ete", "accents et casse : \(f("Élise ÉTÉ"))")
    expect(f("Œuvre cœur") == "oeuvre coeur", "ligature œ")
    expect(f("l’homme") == f("l'homme") && f("l´homme") == "l'homme", "apostrophes unifiées")
    expect(f("forme\u{00A0}marchandise") == "forme marchandise" && f("a\u{202F};") == "a ;", "espaces insécables")
    expect(f("«\u{00A0}texte\u{00A0}»") == "\" texte \"", "guillemets français")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ecritoire-recherche-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Partie"), withIntermediateDirectories: true)
    let a = root.appendingPathComponent("Partie/Méthode.md")
    try """
    ---
    title: "La méthode dialectique"
    synopsis: "motcachedanslentete"
    ---

    # Première partie

    Élise lit l’œuvre de Hegel. La **forme** marchandise apparaît ici.

    ## Le cœur du problème

    Un autre paragraphe : l'homme et la nature, sans le mot cherché.
    """.write(to: a, atomically: true, encoding: .utf8)
    let b = root.appendingPathComponent("Partie/Autre.md")
    try "Texte sans rapport, mais avec une oeuvre et la dialectique plus loin.\n\nLa nature de l’homme.\n".write(to: b, atomically: true, encoding: .utf8)
    let poem = root.appendingPathComponent("Poème.md")
    try "# Titre\n\n---\n\n[1] Demain, dès l’aube, à l’heure où blanchit la campagne,\n\n[2] J’irai par la forêt, j’irai par la montagne.\n".write(to: poem, atomically: true, encoding: .utf8)
    let img = root.appendingPathComponent("Image.md.d")
    try FileManager.default.createDirectory(at: img, withIntermediateDirectories: true)

    let index = SearchIndex(root: root)
    index.build()
    expect(index.documentCount == 3, "3 documents indexés")
    func search(_ q: String) -> SearchIndex.Results { index.search(SearchQuery(q))! }
    func paths(_ q: String) -> [String] { search(q).documents.map(\.relativePath) }

    expect(paths("elise").first == "Partie/Méthode.md", "sans accent → trouve Élise")
    expect(Set(paths("OEUVRE")) == ["Partie/Méthode.md", "Partie/Autre.md"], "oe = œ dans les deux sens : \(paths("OEUVRE"))")
    expect(Set(paths("l’homme")) == ["Partie/Méthode.md", "Partie/Autre.md"], "apostrophe courbe = droite")
    expect(paths("\"forme marchandise\"") == ["Partie/Méthode.md"], "phrase exacte malgré le gras Markdown")
    expect(paths("\"marchandise forme\"").isEmpty, "phrase exacte : l'ordre compte")
    expect(paths("marchandise forme") == ["Partie/Méthode.md"], "plusieurs mots : ordre libre")
    expect(paths("dialect").first == "Partie/Méthode.md" && paths("dialect").count == 2, "préfixe ; titre du document en premier")
    expect(search("dialect").documents.first?.titleMatches == true, "correspondance du titre signalée")
    expect(paths("lectique").isEmpty, "pas de correspondance au milieu d'un mot")
    expect(paths("motcachedanslentete").isEmpty, "en-tête YAML ignoré (sauf le titre)")
    expect(paths("hegel nature") == ["Partie/Méthode.md"], "tous les mots présents dans le document")

    // Positions exactes dans le corps, contexte, intertitre parent.
    if let doc = search("eLiSe").documents.first, let hit = doc.hits.first, let indexed = index.document(at: a) {
        let body = indexed.body as NSString
        expect(body.substring(with: hit.range) == "Élise", "plage exacte dans le texte : « \(body.substring(with: hit.range)) »")
        expect(hit.heading == "Première partie", "intertitre parent : \(hit.heading ?? "-")")
        expect(hit.after.hasPrefix(" lit l’œuvre de Hegel."), "contexte après : « \(hit.after) »")
    } else { expect(false, "résultat Élise") }
    if let hit = search("coeur").documents.first?.hits.first, let indexed = index.document(at: a) {
        expect(hit.isHeading && (indexed.body as NSString).substring(with: hit.range) == "cœur", "intertitre trouvé, plage « cœur »")
    } else { expect(false, "résultat cœur") }
    if let hit = search("marchandise").documents.first?.hits.first {
        expect(hit.before.hasSuffix("La forme ") && !hit.before.contains("**"), "contexte sans syntaxe Markdown : « \(hit.before) »")
    }
    if let hit = search("montagne").documents.first?.hits.first {
        expect(hit.verse == "v. 2", "poème : référence de verset \(hit.verse ?? "-")")
    }
    // Mise à jour après un changement sur le disque.
    try "Nouveau texte : zygomatique.\n".write(to: b, atomically: true, encoding: .utf8)
    index.update(paths: [b.path])
    expect(paths("zygomatique") == ["Partie/Autre.md"] && !paths("oeuvre").contains("Partie/Autre.md"), "index mis à jour")
    try FileManager.default.removeItem(at: b)
    index.update(paths: [b.path])
    expect(paths("zygomatique").isEmpty, "document supprimé retiré de l'index")
}

// Mesure : `swift run -c release EcritoireVerifs --mesure-recherche <dossier>` (lecture seule).
if let i = CommandLine.arguments.firstIndex(of: "--mesure-recherche"), i + 1 < CommandLine.arguments.count {
    let root = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let index = SearchIndex(root: root)
    let t0 = CFAbsoluteTimeGetCurrent()
    index.build()
    print(String(format: "index : %d documents, %.1f M caractères, construit en %.0f ms", index.documentCount,
                 Double(index.characterCount) / 1e6, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
    let typed = ["di", "dia", "dial", "diale", "dialec", "dialect", "dialecti", "dialectiq", "dialectique"]
    let others = ["forme marchandise", "\"lutte des classes\"", "hegel", "oeuvre", "l’homme", "la", "de la", "élan vital", "zzzz"]
    var worst = 0.0
    for q in typed + others {
        var best = Double.infinity
        var result: SearchIndex.Results?
        for _ in 0..<3 {
            let t = CFAbsoluteTimeGetCurrent()
            result = index.search(SearchQuery(q))
            best = min(best, (CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
        worst = max(worst, best)
        print(String(format: "  %-22@ %6.1f ms   %4d documents, %6d occurrences", "« \(q) »" as NSString, best,
                     result?.documents.count ?? 0, result?.totalHits ?? 0))
    }
    print(String(format: "pire temps par frappe : %.1f ms", worst))
    exit(0)
}


// MARK: Export Markdown et PDF

/// Classeur d'essai (textes du domaine public) dans un dossier temporaire.
func exportFixture() throws -> (root: URL, folder: URL, poem: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ecritoire-export-\(UUID().uuidString)")
    let folder = root.appendingPathComponent("Pensées")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try """
    ---
    title: "Le roseau pensant"
    synopsis: "Fragment 347"
    status: "brouillon"
    publish: false
    ---

    # Le roseau pensant

    L’homme n’est qu’un **roseau**, le plus faible de la nature ; mais c’est un ==roseau pensant==.

    %% Note interne à ne pas exporter %%

    ## La pensée

    > Toute notre dignité consiste donc en la pensée.

    Voir [[Divertissement|le divertissement]] et <mark class="vert">l’ennui</mark>.

    ![[gravure.png]]

    [1](https://example.org/note) Renvoi de note, pas un verset.

    [2](https://example.org/note2) Second renvoi.
    """.write(to: folder.appendingPathComponent("Roseau.md"), atomically: true, encoding: .utf8)
    try """
    ---
    title: "Divertissement"
    ---

    Le divertissement nous amuse et nous fait arriver insensiblement à la mort.
    """.write(to: folder.appendingPathComponent("Divertissement.md"), atomically: true, encoding: .utf8)
    try Binder.writeOrder(["Roseau.md", "Divertissement.md"], in: folder)
    // Image PNG minuscule (1 × 1).
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
    try png.write(to: folder.appendingPathComponent("gravure.png"))
    let poem = root.appendingPathComponent("Demain.md")
    try """
    # Demain, dès l’aube

    Victor Hugo, Les Contemplations.

    ---

    [1] Demain, dès l’aube, à l’heure où blanchit la campagne,

    [2] Je partirai. Vois-tu, je sais que tu m’attends.

    [3] J’irai par la forêt, j’irai par la montagne.
    """.write(to: poem, atomically: true, encoding: .utf8)
    return (root, folder, poem)
}

/// Empreinte de tous les fichiers d'un dossier (pour vérifier que l'export ne modifie rien).
func snapshot(_ folder: URL) -> [String: Data] {
    var out: [String: Data] = [:]
    let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
    while let url = e?.nextObject() as? URL {
        if let data = try? Data(contentsOf: url) { out[url.path] = data }
    }
    return out
}

func exportMarkdownTests() throws {
    let (root, folder, poem) = try exportFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = snapshot(root)
    // Dossier : un seul texte, ordre du classeur, intertitres, titres internes décalés.
    let sections = Export.sections(for: folder, root: root)
    expect(sections.map(\.title) == ["Pensées", "Le roseau pensant", "Divertissement"], "\(sections.map(\.title))")
    expect(sections.map(\.level) == [1, 2, 2])
    expect(!sections[1].poem, "des renvois de note [1](…) ne font pas un poème")
    let out = root.appendingPathComponent("export")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let files = try Export.writeMarkdown(sections, to: out.appendingPathComponent("Pensées.md"))
    let md = try String(contentsOf: files[0], encoding: .utf8)
    expect(md.hasPrefix("# Pensées\n\n## Le roseau pensant\n\n"), "titre du dossier puis intertitre")
    expect(!md.contains("title:") && !md.contains("synopsis"), "sans en-tête YAML")
    expect(md.components(separatedBy: "Le roseau pensant").count == 2, "titre en double retiré")
    expect(md.contains("\n### La pensée\n"), "titre interne décalé d'un niveau")
    expect(!md.contains("%%") && !md.contains("Note interne"), "commentaires internes retirés")
    expect(md.contains("roseau pensant.") && !md.contains("==") && !md.contains("<mark"), "surligneurs retirés")
    expect(md.contains("**roseau**"), "gras conservé")
    expect(md.contains("Voir le divertissement et l’ennui."), "lien interne : son libellé")
    expect(md.contains("![gravure](gravure.png)"), "image en syntaxe Markdown standard")
    expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("gravure.png").path), "image copiée à côté")
    expect(md.contains("[1](https://example.org/note) Renvoi"), "renvoi de note intact")
    expect(md.contains("## Divertissement\n\nLe divertissement nous amuse"), "second document dans l'ordre")
    // Poème : titre en tête, vers sans leurs numéros.
    let poemSections = Export.sections(for: poem, root: root)
    expect(poemSections.count == 1 && poemSections[0].poem && poemSections[0].title == "Demain, dès l’aube")
    let poemMD = Export.markdown(poemSections).text
    expect(poemMD.hasPrefix("# Demain, dès l’aube\n\nVictor Hugo"), String(poemMD.prefix(60)))
    expect(poemMD.contains("\nDemain, dès l’aube, à l’heure") && !poemMD.contains("[1]") && !poemMD.contains("[3]"), "vers sans [n]")
    expect(snapshot(root).filter { !$0.key.contains("/export/") } == before, "sources inchangées")
}

/// Export PDF de bout en bout, par l'application elle-même (`Ecritoire --exporter`), lu avec PDFKit.
func exportPDFTests() throws {
    let app = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("Ecritoire")
    guard FileManager.default.isExecutableFile(atPath: app.path) else {
        print("  (application non construite : export PDF non vérifié — `swift build` d'abord)")
        return
    }
    let (root, folder, poem) = try exportFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = snapshot(root)
    func export(_ source: URL, _ name: String) throws -> PDFDocument? {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        let p = Process()
        p.executableURL = app
        p.arguments = ["--exporter", source.path, destination.path, "--racine", root.path]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        expect(p.terminationStatus == 0, "export de \(name)")
        defer { try? FileManager.default.removeItem(at: destination) }
        return PDFDocument(url: destination)
    }
    guard let pdf = try export(folder, "dossier.pdf"), let page = pdf.page(at: 0) else { expect(false, "PDF lisible"); return }
    let box = page.bounds(for: .mediaBox)
    expect(abs(box.width - 595.28) < 1 && abs(box.height - 841.89) < 1, "format A4 (\(box.size))")
    let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
    expect(text.contains("Pensées") && text.contains("Le roseau pensant") && text.contains("Divertissement"), "titres")
    expect(text.contains("roseau pensant") && text.contains("Toute notre dignité"), "texte et citation")
    for sign in ["**", "==", "%%", "<mark", "[[", "# ", "> ", "title:"] {
        expect(!text.contains(sign), "aucun signe Markdown « \(sign) » dans le texte du PDF")
    }
    expect(!text.contains("Note interne"), "commentaires absents")
    expect((page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("1"), "numéro de page")
    guard let poemPDF = try export(poem, "poeme.pdf") else { expect(false, "PDF du poème"); return }
    let poemText = (0..<poemPDF.pageCount).compactMap { poemPDF.page(at: $0)?.string }.joined(separator: "\n")
    expect(poemText.contains("Demain, dès l’aube, à l’heure où blanchit la campagne,"), "vers du poème")
    expect(!poemText.contains("[1]") && !poemText.contains("[2]"), "vers sans [n]")
    expect(snapshot(root) == before, "sources inchangées")
}

let f = FrontmatterTests()
run("En-tête YAML : lecture et réécriture", f.parseAndSerializeRoundTrip)
run("En-tête YAML : document sans en-tête", f.documentWithoutFrontmatter)
run("Compteur de mots", f.wordCount)
run("Classeur : ordre manuel et création") { try BinderTests().manualOrderAndCreation() }
run("Classeur : réordonner dans un dossier") { try BinderTests().reorderWithinFolder() }
run("Classeur : déplacer entre dossiers et renommer") { try BinderTests().moveBetweenFoldersAndRename() }
run("Classeur : chargement de l'arbre") { try BinderTests().treeLoading() }
run("Surveillance FSEvents", watcherDetectsExternalWrite)
run("Différences entre versions", diffTests)
run("Ancrage des commentaires", anchorTests)
run("Fichiers annexes (.ecritoire)", sidecarTests)
run("Poème : versets, renumérotation, références", poemTests)
run("Recherche : normalisation, termes, contexte", searchTests)
run("Export Markdown : dossier, poème, images, sources intactes", exportMarkdownTests)
run("Export PDF : A4, texte sans signes, poème, sources intactes", exportPDFTests)
print("\n\(checks) vérifications, \(failures) échec(s)")
exit(failures == 0 ? 0 : 1)
