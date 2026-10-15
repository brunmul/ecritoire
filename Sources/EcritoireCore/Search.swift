import Foundation

// MARK: - Normalisation

/// Forme « repliée » d'un texte pour la recherche : minuscules, sans accents (é = e), ligatures dépliées (œ = oe),
/// apostrophes et guillemets unifiés (’ = '), espaces insécables = espace, blancs regroupés.
/// En mode Markdown, la syntaxe est ignorée (`**`, `==`, `[[ ]]`, balises, `#` et `>` de début de ligne,
/// numéros de versets `[n]`, lignes d'image), si bien que « **forme** marchandise » se trouve avec « forme marchandise ».
public enum SearchFold {
    /// Correspondance d'un caractère non ASCII → octets repliés (cache partagé, protégé par un verrou).
    nonisolated(unsafe) private static var cache: [UInt32: [UInt8]] = [:]
    private static let lock = NSLock()

    private static func foldScalar(_ scalar: Unicode.Scalar) -> [UInt8] {
        let v = scalar.value
        switch v {
        case 0x2019, 0x2018, 0x02BC, 0x0060, 0x00B4, 0x2032: return [0x27]          // ’ ‘ ʼ ` ´ ′ → '
        case 0x201C, 0x201D, 0x00AB, 0x00BB, 0x201E, 0x2033: return [0x22]          // “ ” « » „ → "
        case 0x00A0, 0x202F, 0x2009, 0x2007, 0x2002, 0x2003, 0x200A: return [0x20]  // espaces fines et insécables
        case 0x200B, 0x00AD, 0xFEFF: return []                                       // invisibles
        case 0x0153, 0x0152: return [0x6F, 0x65]                                     // œ
        case 0x00E6, 0x00C6: return [0x61, 0x65]                                     // æ
        case 0x00DF: return [0x73, 0x73]                                             // ß
        case 0x2010, 0x2011: return [0x2D]                                           // traits d'union
        default: break
        }
        lock.lock()
        if let hit = cache[v] { lock.unlock(); return hit }
        lock.unlock()
        let folded = String(Character(scalar)).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        var bytes = Array(folded.utf8)
        if bytes.count == 1, bytes[0] >= 0x41, bytes[0] <= 0x5A { bytes[0] += 0x20 }
        lock.lock(); cache[v] = bytes; lock.unlock()
        return bytes
    }

    @inline(__always) static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b >= 0x80
    }

    /// Requête : repliée sans règles Markdown.
    public static func query(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        fold(text, markdown: false, into: &out, map: nil, paragraphs: nil)
        while out.last == 0x20 || out.last == 0x0A { out.removeLast() }
        while out.first == 0x20 { out.removeFirst() }
        return out
    }

    /// Replie `text`. `map` (si fourni) reçoit, pour chaque octet produit, la position UTF-16 du caractère d'origine.
    /// `paragraphs` reçoit (octet replié, position UTF-16) au début de chaque paragraphe.
    public static func fold(_ text: String, markdown: Bool, into out: inout [UInt8], map: UnsafeMutablePointer<[Int32]>?,
                            paragraphs: UnsafeMutablePointer<[(folded: Int32, original: Int32)]>?) {
        let scalars = Array(text.unicodeScalars)
        var utf16 = 0
        var i = 0
        var lineStart = true
        var lastSpace = true
        paragraphs?.pointee.append((Int32(out.count), 0))
        @inline(__always) func emit(_ b: UInt8, _ at: Int) {
            out.append(b)
            map?.pointee.append(Int32(at))
        }
        func skip(_ n: Int) {
            for k in 0..<n where i + k < scalars.count { utf16 += Int(scalars[i + k].utf16.count) }
            i += n
        }
        while i < scalars.count {
            let s = scalars[i]
            let v = s.value
            if v == 0x0A || v == 0x0D || v == 0x2029 {
                // Fin de paragraphe : un seul « \n » replié, quel que soit le nombre de lignes vides.
                if out.last != 0x0A && !out.isEmpty {
                    if out.last == 0x20 { out.removeLast(); map?.pointee.removeLast() }
                    emit(0x0A, utf16)
                }
                skip(1)
                lineStart = true
                lastSpace = true
                paragraphs?.pointee.append((Int32(out.count), Int32(utf16)))
                continue
            }
            if markdown {
                if lineStart {
                    // Marqueurs de début de ligne : titres, citations, numéros de versets, lignes d'image.
                    var j = i
                    while j < scalars.count, scalars[j].value == 0x23 || scalars[j].value == 0x3E || scalars[j].value == 0x20 { j += 1 }
                    if j < scalars.count, scalars[j].value == 0x5B { // [n] ou [!intro]
                        var k = j + 1
                        while k < scalars.count, (scalars[k].value >= 0x30 && scalars[k].value <= 0x39) { k += 1 }
                        if k > j + 1, k < scalars.count, scalars[k].value == 0x5D {
                            j = k + 1
                            while j < scalars.count, scalars[j].value == 0x20 { j += 1 }
                        }
                    }
                    let calloutHeader = j + 1 < scalars.count && scalars[j].value == 0x5B && scalars[j + 1].value == 0x21
                    if calloutHeader || (j < scalars.count && scalars[j].value == 0x21 && j + 2 < scalars.count
                                         && scalars[j + 1].value == 0x5B && scalars[j + 2].value == 0x5B) {
                        // ![[image]] ou > [!intro] : ligne ignorée
                        while j < scalars.count, scalars[j].value != 0x0A { j += 1 }
                    }
                    if j > i { skip(j - i) }
                    lineStart = false
                    continue
                }
                switch v {
                case 0x2A, 0x5F: skip(1); continue                                    // * _
                case 0x3D where (i + 1 < scalars.count && scalars[i + 1].value == 0x3D) || (i > 0 && scalars[i - 1].value == 0x3D):
                    skip(1); continue                                                // ==
                case 0x5B where i + 1 < scalars.count && scalars[i + 1].value == 0x5B: skip(2); continue // [[
                case 0x5D where i + 1 < scalars.count && scalars[i + 1].value == 0x5D: skip(2); continue // ]]
                case 0x3C where i + 1 < scalars.count && (scalars[i + 1].properties.isAlphabetic || scalars[i + 1].value == 0x2F):
                    // Balise HTML (<mark class="…">, </mark>) : ignorée jusqu'au « > ».
                    var j = i + 1
                    while j < scalars.count, scalars[j].value != 0x3E, scalars[j].value != 0x0A, j - i < 80 { j += 1 }
                    if j < scalars.count, scalars[j].value == 0x3E { skip(j - i + 1); continue }
                default: break
                }
            }
            lineStart = false
            if v < 0x80 {
                var b = UInt8(v)
                if b == 0x09 { b = 0x20 }
                if b == 0x20 {
                    if !lastSpace { emit(0x20, utf16) }
                    lastSpace = true
                } else {
                    if b >= 0x41 && b <= 0x5A { b += 0x20 }
                    emit(b, utf16)
                    lastSpace = false
                }
            } else {
                let bytes = foldScalar(s)
                if bytes == [0x20] {
                    if !lastSpace { emit(0x20, utf16) }
                    lastSpace = true
                } else {
                    for b in bytes { emit(b, utf16) }
                    if !bytes.isEmpty { lastSpace = false }
                }
            }
            skip(1)
        }
    }
}

// MARK: - Requête

public struct SearchQuery: Sendable {
    /// Termes repliés : mots (préfixes de mots) et phrases exactes entre guillemets.
    public let terms: [[UInt8]]

    public init(_ text: String) {
        var terms: [[UInt8]] = []
        var current = ""
        var inQuote = false
        func flush() {
            let folded = SearchFold.query(current)
            if !folded.isEmpty { terms.append(folded) }
            current = ""
        }
        for ch in text {
            if ch == "\"" || ch == "“" || ch == "”" || ch == "«" || ch == "»" {
                flush()
                inQuote.toggle()
            } else if ch.isWhitespace && !inQuote {
                flush()
            } else {
                current.append(ch)
            }
        }
        flush()
        // Les mots d'une seule lettre hors guillemets ne filtrent rien d'utile et coûtent cher.
        self.terms = terms.count > 1 ? terms.filter { $0.count > 1 } : terms
    }

    public var isEmpty: Bool { terms.isEmpty || (terms.count == 1 && terms[0].count < 2) }
}

// MARK: - Index

/// Un document indexé : titre, intertitres, texte replié et table des paragraphes.
public final class IndexedDocument: @unchecked Sendable {
    public let url: URL
    public let relativePath: String
    public let title: String
    let foldedTitle: [UInt8]
    /// Corps (sans en-tête YAML), tel que l'éditeur l'affiche : les positions des résultats s'y rapportent.
    public let body: String
    let folded: [UInt8]
    /// Début de chaque paragraphe : octet replié et position UTF-16 dans le corps.
    let paragraphs: [(folded: Int32, original: Int32)]
    /// Intertitres : position UTF-16, niveau, texte.
    public let headings: [(location: Int, level: Int, title: String)]
    let foldedHeadings: [[UInt8]]
    public let isPoem: Bool
    let modified: Date

    init(url: URL, relativePath: String, text: String, modified: Date) {
        self.url = url
        self.relativePath = relativePath
        self.modified = modified
        let doc = MarkdownDocument.parse(text, defaultTitle: url.deletingPathExtension().lastPathComponent)
        // Sans en-tête YAML (un poème, par exemple), le premier titre « # … » sert de titre.
        let fileName = url.deletingPathExtension().lastPathComponent
        let firstHeading = text.hasPrefix("---") ? nil : text.split(separator: "\n", maxSplits: 1).first
            .flatMap { $0.hasPrefix("# ") ? String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) : nil }
        title = firstHeading ?? (doc.title.isEmpty ? fileName : doc.title)
        body = doc.body
        foldedTitle = SearchFold.query(title)
        var out: [UInt8] = []
        out.reserveCapacity(doc.body.utf8.count)
        var paras: [(folded: Int32, original: Int32)] = []
        SearchFold.fold(doc.body, markdown: true, into: &out, map: nil, paragraphs: &paras)
        folded = out
        paragraphs = paras
        var heads: [(Int, Int, String)] = []
        let ns = doc.body as NSString
        var inFence = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, range, _, _ in
            guard let line, !line.isEmpty else { return }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); return }
            guard !inFence, line.hasPrefix("#") else { return }
            let level = line.prefix(while: { $0 == "#" }).count
            guard level <= 6, line.dropFirst(level).first == " " else { return }
            let t = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"\*\*|__|(?<!\\)\*|\[\[|\]\]|=="#, with: "", options: .regularExpression)
            heads.append((range.location, level, t))
        }
        headings = heads
        foldedHeadings = heads.map { SearchFold.query($0.2) }
        isPoem = Poem.isPoem(doc.body)
    }

    /// Paragraphe (indice) qui contient un octet replié.
    func paragraphIndex(ofFolded offset: Int) -> Int {
        var low = 0, high = paragraphs.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if Int(paragraphs[mid].folded) <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// Index en mémoire d'un dossier (un classeur, ou tous les classeurs). Rien n'est écrit dans les fichiers.
public final class SearchIndex: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private var documents: [String: IndexedDocument] = [:] // chemin → document
    public private(set) var isReady = false

    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    public var documentCount: Int { lock.lock(); defer { lock.unlock() }; return documents.count }
    public var characterCount: Int { lock.lock(); defer { lock.unlock() }; return documents.values.reduce(0) { $0 + $1.body.utf16.count } }

    /// Tous les documents `.md` du dossier (hors dossiers cachés, paquets et dossiers nommés « x.md »).
    public static func markdownFiles(in root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension.lowercased() == "md" {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory != true { out.append(url) }
        }
        return out
    }

    private func relative(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : url.lastPathComponent
    }

    /// Construction complète, en parallèle sur plusieurs cœurs.
    public func build() {
        let files = Self.markdownFiles(in: root)
        var built = [IndexedDocument?](repeating: nil, count: files.count)
        built.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                base[i] = self.load(files[i])
            }
        }
        lock.lock()
        documents = [:]
        for doc in built.compactMap({ $0 }) { documents[doc.relativePath] = doc }
        isReady = true
        lock.unlock()
    }

    private func load(_ url: URL) -> IndexedDocument? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return IndexedDocument(url: url, relativePath: relative(url), text: text, modified: modified)
    }

    /// Mise à jour après un changement sur le disque (FSEvents) : documents modifiés, créés, supprimés ou déplacés.
    public func update(paths: [String]) {
        var touched = false
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            if exists && isDir.boolValue || !exists && url.pathExtension.lowercased() != "md" {
                touched = true // dossier créé, renommé ou supprimé : on revérifie tout plus bas
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let key = relative(url)
            let doc = exists ? load(url) : nil
            lock.lock(); documents[key] = doc; lock.unlock()
        }
        if touched { reconcile() }
    }

    /// Ajoute les documents apparus et retire ceux qui ont disparu (après un renommage de dossier).
    public func reconcile() {
        let files = Self.markdownFiles(in: root)
        let keys = Set(files.map(relative))
        lock.lock()
        let missing = files.filter { documents[relative($0)] == nil }
        for key in documents.keys where !keys.contains(key) { documents[key] = nil }
        lock.unlock()
        for url in missing {
            if let doc = load(url) { lock.lock(); documents[doc.relativePath] = doc; lock.unlock() }
        }
    }

    /// Document indexé (pour les vérifications).
    public func document(at url: URL) -> IndexedDocument? {
        lock.lock(); defer { lock.unlock() }
        return documents[relative(url)]
    }

    // MARK: Recherche

    public struct Hit: Identifiable, Sendable {
        public let id: String
        /// Plage dans le corps du document (UTF-16), à sélectionner dans l'éditeur.
        public let range: NSRange
        public let before: String
        public let match: String
        public let after: String
        /// Intertitre parent (ou l'intertitre lui-même pour un résultat de titre).
        public let heading: String?
        public let isHeading: Bool
        /// Référence de verset pour un poème (« v. 12 »).
        public let verse: String?
    }

    public struct DocumentResult: Identifiable, Sendable {
        public var id: String { relativePath }
        public let url: URL
        public let relativePath: String
        public let title: String
        public let titleMatches: Bool
        public let count: Int
        public let hits: [Hit]
    }

    public struct Results: Sendable {
        public let documents: [DocumentResult]
        public let totalHits: Int
        public let searchedDocuments: Int
        public let milliseconds: Double
    }

    /// Recherche : documents dont le titre ou le texte contient tous les termes ; dans le texte, les paragraphes
    /// qui contiennent tous les termes (à défaut, ceux du terme le plus rare). `cancelled` permet d'abandonner.
    /// Le contexte n'est préparé que pour les premières occurrences de chaque document (`moreHits` pour la suite).
    public func search(_ query: SearchQuery, maxHitsPerDocument: Int = 8, maxDocuments: Int = 100,
                       cancelled: @escaping @Sendable () -> Bool = { false }) -> Results? {
        let start = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let docs = Array(documents.values)
        lock.unlock()
        guard !query.isEmpty else { return Results(documents: [], totalHits: 0, searchedDocuments: docs.count, milliseconds: 0) }
        // 1. Comptage, en parallèle, sans garder les positions.
        struct Match { let doc: IndexedDocument; let title: Bool; let heading: Bool; let count: Int }
        var matches = [Match?](repeating: nil, count: docs.count)
        let terms = query.terms
        matches.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: docs.count) { i in
                if i % 64 == 0, cancelled() { return }
                let doc = docs[i]
                let title = terms.allSatisfy { Self.count($0, in: doc.foldedTitle, limit: 1) > 0 }
                var count = Int.max
                for term in terms {
                    count = min(count, Self.count(term, in: doc.folded, limit: Self.countLimit))
                    if count == 0 { break }
                }
                guard title || count > 0 else { return }
                let heading = !title && count > 0 && doc.foldedHeadings.contains { f in
                    terms.allSatisfy { Self.count($0, in: f, limit: 1) > 0 }
                }
                base[i] = Match(doc: doc, title: title, heading: heading, count: count)
            }
        }
        if cancelled() { return nil }
        // 2. Titres d'abord, puis documents dont un intertitre correspond, puis par nombre d'occurrences.
        let ranked = matches.compactMap { $0 }.sorted { a, b in
            if a.title != b.title { return a.title }
            if a.heading != b.heading { return a.heading }
            if a.count != b.count { return a.count > b.count }
            return a.doc.relativePath.localizedStandardCompare(b.doc.relativePath) == .orderedAscending
        }
        let total = ranked.reduce(0) { $0 + $1.count }
        // 3. Occurrences avec contexte pour les documents affichés (en parallèle).
        let shown = Array(ranked.prefix(maxDocuments))
        var results = [DocumentResult?](repeating: nil, count: shown.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: shown.count) { i in
                if cancelled() { return }
                let m = shown[i]
                let hits = m.count > 0 ? Self.hits(in: m.doc, terms: terms, limit: maxHitsPerDocument) : []
                base[i] = DocumentResult(url: m.doc.url, relativePath: m.doc.relativePath, title: m.doc.title,
                                         titleMatches: m.title, count: m.count, hits: hits)
            }
        }
        if cancelled() { return nil }
        return Results(documents: results.compactMap { $0 }, totalHits: total, searchedDocuments: docs.count,
                       milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    /// Au-delà, on affiche « 2 000+ » : compter toutes les occurrences de « la » ne sert à rien.
    public static let countLimit = 2000

    /// Toutes les occurrences affichables d'un document (bouton « afficher les autres »).
    public func moreHits(in url: URL, query: SearchQuery, limit: Int = 500) -> [Hit] {
        guard let doc = document(at: url), !query.isEmpty else { return [] }
        return Self.hits(in: doc, terms: query.terms, limit: limit)
    }

    /// Nombre d'occurrences en début de mot, sans allocation.
    static func count(_ term: [UInt8], in haystack: [UInt8], limit: Int) -> Int {
        guard !term.isEmpty, haystack.count >= term.count else { return 0 }
        var n = 0
        let startsWithWord = SearchFold.isWordByte(term[0])
        term.withUnsafeBytes { needle in
            haystack.withUnsafeBytes { hay in
                guard let base = hay.baseAddress, let p0 = needle.baseAddress else { return }
                var offset = 0
                while offset <= hay.count - needle.count, n < limit {
                    guard let p = memmem(base + offset, hay.count - offset, p0, needle.count) else { break }
                    let pos = base.distance(to: p)
                    if !startsWithWord || pos == 0 || !SearchFold.isWordByte(hay[pos - 1]) { n += 1 }
                    offset = pos + 1
                }
            }
        }
        return n
    }

    /// Occurrences d'un terme replié au début d'un mot (préfixe), par memmem.
    static func find(_ term: [UInt8], in haystack: [UInt8], limit: Int) -> [Int] {
        guard !term.isEmpty, haystack.count >= term.count else { return [] }
        var out: [Int] = []
        let startsWithWord = SearchFold.isWordByte(term[0])
        term.withUnsafeBytes { needle in
            haystack.withUnsafeBytes { hay in
                guard let base = hay.baseAddress, let n = needle.baseAddress else { return }
                var offset = 0
                while offset <= hay.count - needle.count, out.count < limit {
                    guard let p = memmem(base + offset, hay.count - offset, n, needle.count) else { break }
                    let pos = base.distance(to: p)
                    let previous = pos > 0 ? hay[pos - 1] : 0x20
                    // Début de mot : l'octet précédent n'est ni une lettre ni un chiffre (une suite UTF-8 compte comme lettre).
                    if !startsWithWord || !SearchFold.isWordByte(previous) {
                        out.append(pos)
                    }
                    offset = pos + 1
                }
            }
        }
        return out
    }

    /// Occurrences affichées : paragraphes qui contiennent tous les termes (intertitres d'abord), avec leur contexte.
    static func hits(in doc: IndexedDocument, terms: [[UInt8]], limit: Int) -> [Hit] {
        let perTerm = terms.map { find($0, in: doc.folded, limit: 20_000) }
        guard perTerm.allSatisfy({ !$0.isEmpty }) else { return [] }
        // Paragraphes de chaque terme.
        let sets = perTerm.map { Set($0.map(doc.paragraphIndex(ofFolded:))) }
        var common = sets.dropFirst().reduce(sets[0]) { $0.intersection($1) }
        var anchorTerm = 0
        if common.isEmpty {
            anchorTerm = perTerm.indices.min { perTerm[$0].count < perTerm[$1].count } ?? 0
            common = sets[anchorTerm]
        }
        // Première occurrence du terme d'ancrage dans chaque paragraphe retenu.
        var firstInParagraph: [Int: Int] = [:]
        for pos in perTerm[anchorTerm] {
            let p = doc.paragraphIndex(ofFolded: pos)
            if common.contains(p), firstInParagraph[p] == nil { firstInParagraph[p] = pos }
        }
        let headingStarts = Set(doc.headings.map(\.location))
        let ordered = firstInParagraph.keys.sorted().map { p -> (Int, Bool) in
            (p, headingStarts.contains(Int(doc.paragraphs[p].original)))
        }.sorted { a, b in a.1 != b.1 ? a.1 : a.0 < b.0 }
        var out: [Hit] = []
        for (p, isHeading) in ordered.prefix(limit) {
            guard let hit = makeHit(doc, paragraph: p, foldedPosition: firstInParagraph[p]!, termLength: terms[anchorTerm].count, isHeading: isHeading) else { continue }
            out.append(hit)
        }
        return out
    }

    /// Contexte d'une occurrence : le paragraphe d'origine est replié de nouveau, avec la correspondance des positions.
    static func makeHit(_ doc: IndexedDocument, paragraph p: Int, foldedPosition: Int, termLength: Int, isHeading: Bool) -> Hit? {
        let ns = doc.body as NSString
        let paraStart = Int(doc.paragraphs[p].original)
        guard paraStart <= ns.length else { return nil }
        let paraRange = ns.paragraphRange(for: NSRange(location: paraStart, length: 0))
        let paragraph = ns.substring(with: paraRange)
        var folded: [UInt8] = []
        var map: [Int32] = []
        SearchFold.fold(paragraph, markdown: true, into: &folded, map: &map, paragraphs: nil)
        let local = foldedPosition - Int(doc.paragraphs[p].folded)
        guard local >= 0, local + termLength <= map.count, termLength > 0 else { return nil }
        let startLocal = Int(map[local])
        // Fin : début du caractère suivant le dernier octet du terme.
        let lastChar = Int(map[local + termLength - 1])
        let pns = paragraph as NSString
        let endLocal = NSMaxRange(pns.rangeOfComposedCharacterSequence(at: min(lastChar, max(0, pns.length - 1))))
        let matchRange = NSRange(location: startLocal, length: max(0, endLocal - startLocal))
        let before = contextBefore(pns, upTo: matchRange.location)
        let after = contextAfter(pns, from: NSMaxRange(matchRange))
        let range = NSRange(location: paraRange.location + matchRange.location, length: matchRange.length)
        let parent = isHeading ? nil : doc.headings.last { $0.location < paraRange.location }?.title
        let verse = doc.isPoem ? Poem.reference(for: range, in: doc.body) : nil
        return Hit(id: "\(doc.relativePath)#\(range.location)", range: range, before: clean(before), match: clean(pns.substring(with: matchRange)),
                   after: clean(after), heading: parent, isHeading: isHeading, verse: verse)
    }

    /// Environ une phrase avant le terme : depuis le début de la phrase en cours (et la précédente si elle commence
    /// juste avant), 160 caractères au plus, coupé à un mot.
    static func contextBefore(_ text: NSString, upTo location: Int) -> String {
        let window = max(0, location - 160)
        let slice = text.substring(with: NSRange(location: window, length: location - window)) as NSString
        var start = 0
        var ellipsis = window > 0
        var search = NSRange(location: 0, length: slice.length)
        // Fin de la phrase précédente ; si le terme ouvre presque sa phrase, on remonte d'une phrase.
        for _ in 0..<2 {
            let r = slice.range(of: #"[.!?…]["»”)]?\s+"#, options: [.regularExpression, .backwards], range: search)
            guard r.location != NSNotFound else { break }
            start = NSMaxRange(r)
            ellipsis = false
            if slice.length - start >= 40 || r.location == 0 { break }
            search = NSRange(location: 0, length: r.location)
        }
        if ellipsis {
            let space = slice.range(of: " ")
            if space.location != NSNotFound, space.location < 30 { start = NSMaxRange(space) }
        }
        return (ellipsis ? "…" : "") + slice.substring(from: start)
    }

    /// Environ une phrase après le terme (jusqu'à la fin de la phrase, 160 caractères au plus).
    static func contextAfter(_ text: NSString, from location: Int) -> String {
        let end = min(text.length, location + 160)
        let slice = text.substring(with: NSRange(location: location, length: end - location))
        if let r = slice.range(of: #"[.!?](\s|$)"#, options: .regularExpression), slice.distance(from: slice.startIndex, to: r.lowerBound) > 20 {
            return String(slice[..<r.upperBound]).trimmingCharacters(in: .newlines)
        }
        var s = slice.trimmingCharacters(in: .newlines)
        if end < text.length, let space = s.lastIndex(of: " ") { s = String(s[..<space]) + "…" }
        return s
    }

    /// Texte affichable : syntaxe Markdown retirée.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<[^>\n]{1,80}>|\*\*|__|==|\[\[|\]\]|(?<![\w])[*_]|[*_](?![\w])"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^(#{1,6}|>|\[\d+\])\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!>])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "\n", with: " ")
        return t
    }
}
