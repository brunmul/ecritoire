import Foundation

/// Une modification entre deux versions d'un texte (positions en UTF-16, comme NSString).
public struct DiffHunk: Equatable, Sendable {
    /// Plage remplacée dans l'ancienne version.
    public var baseRange: NSRange
    /// Plage correspondante dans la nouvelle version.
    public var currentRange: NSRange
    public var deleted: String
    public var inserted: String
}

/// Différence lisible entre deux versions : d'abord par paragraphe (rapide sur de longs textes),
/// puis mot à mot à l'intérieur des paragraphes modifiés.
public enum TextDiff {
    public static func hunks(from base: String, to current: String) -> [DiffHunk] {
        if base == current { return [] }
        let baseLines = lines(base), currentLines = lines(current)
        var result: [DiffHunk] = []
        for block in blocks(baseLines.map(\.text), currentLines.map(\.text)) {
            let baseStart = block.baseRange.lowerBound < baseLines.count ? baseLines[block.baseRange.lowerBound].offset : (base as NSString).length
            let currentStart = block.currentRange.lowerBound < currentLines.count ? currentLines[block.currentRange.lowerBound].offset : (current as NSString).length
            let deleted = baseLines[block.baseRange].map(\.text).joined()
            let inserted = currentLines[block.currentRange].map(\.text).joined()
            let lineHunk = DiffHunk(baseRange: NSRange(location: baseStart, length: (deleted as NSString).length),
                                    currentRange: NSRange(location: currentStart, length: (inserted as NSString).length),
                                    deleted: deleted, inserted: inserted)
            // Remplacement d'un passage de taille raisonnable : on affine au mot près.
            if !deleted.isEmpty && !inserted.isEmpty && deleted.utf16.count + inserted.utf16.count < 40_000 {
                result += refine(lineHunk)
            } else {
                result.append(lineHunk)
            }
        }
        return result
    }

    // MARK: Découpage

    private struct Piece { let text: String; let offset: Int }

    /// Lignes (paragraphes) avec leur retour à la ligne final.
    private static func lines(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var offset = 0
        var current = ""
        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if scalar == "\n" {
                out.append(Piece(text: current, offset: offset))
                offset += current.utf16.count
                current = ""
            }
        }
        if !current.isEmpty { out.append(Piece(text: current, offset: offset)) }
        return out
    }

    /// Mots, espaces et ponctuation séparés.
    private static func tokens(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var offset = 0
        var current = ""
        var currentKind = -1
        func kind(_ c: Character) -> Int { c.isLetter || c.isNumber ? 0 : (c.isWhitespace ? 1 : 2) }
        for c in text {
            let k = kind(c)
            if k != currentKind || k == 2 {
                if !current.isEmpty { out.append(Piece(text: current, offset: offset)); offset += current.utf16.count }
                current = ""
                currentKind = k
            }
            current.append(c)
        }
        if !current.isEmpty { out.append(Piece(text: current, offset: offset)) }
        return out
    }

    /// Blocs modifiés (plages d'indices) entre deux suites, via la différence de la bibliothèque standard.
    private static func blocks(_ a: [String], _ b: [String]) -> [(baseRange: Range<Int>, currentRange: Range<Int>)] {
        // Préfixe et suffixe communs retirés d'abord : la plupart des révisions sont locales.
        var start = 0
        while start < a.count && start < b.count && a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start && endB > start && a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        let midA = Array(a[start..<endA]), midB = Array(b[start..<endB])
        let diff = midB.difference(from: midA)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0
        while i < midA.count || j < midB.count {
            if removed.contains(i) || inserted.contains(j) {
                let i0 = i, j0 = j
                while i < midA.count && removed.contains(i) { i += 1 }
                while j < midB.count && inserted.contains(j) { j += 1 }
                result.append(((start + i0)..<(start + i), (start + j0)..<(start + j)))
            } else {
                i += 1; j += 1
            }
        }
        return result
    }

    private static func refine(_ hunk: DiffHunk) -> [DiffHunk] {
        let a = tokens(hunk.deleted), b = tokens(hunk.inserted)
        var out: [DiffHunk] = []
        for block in blocks(a.map(\.text), b.map(\.text)) {
            let aStart = block.baseRange.lowerBound < a.count ? a[block.baseRange.lowerBound].offset : hunk.deleted.utf16.count
            let bStart = block.currentRange.lowerBound < b.count ? b[block.currentRange.lowerBound].offset : hunk.inserted.utf16.count
            let deleted = a[block.baseRange].map(\.text).joined()
            let inserted = b[block.currentRange].map(\.text).joined()
            out.append(DiffHunk(baseRange: NSRange(location: hunk.baseRange.location + aStart, length: deleted.utf16.count),
                                currentRange: NSRange(location: hunk.currentRange.location + bStart, length: inserted.utf16.count),
                                deleted: deleted, inserted: inserted))
        }
        return merge(out, base: hunk)
    }

    /// Fusionne deux modifications séparées par un seul espace (« le chat noir » → « un chien blanc » : un seul bloc).
    private static func merge(_ hunks: [DiffHunk], base: DiffHunk) -> [DiffHunk] {
        guard var current = hunks.first else { return [] }
        var out: [DiffHunk] = []
        let baseText = base.deleted as NSString, curText = base.inserted as NSString
        for next in hunks.dropFirst() {
            let gapBase = next.baseRange.location - NSMaxRange(current.baseRange)
            let gapCur = next.currentRange.location - NSMaxRange(current.currentRange)
            let gapText = baseText.substring(with: NSRange(location: NSMaxRange(current.baseRange) - base.baseRange.location, length: max(0, gapBase)))
            if gapBase == gapCur && gapBase <= 1 && gapText.trimmingCharacters(in: .whitespaces).isEmpty {
                let bRange = NSRange(location: current.baseRange.location, length: NSMaxRange(next.baseRange) - current.baseRange.location)
                let cRange = NSRange(location: current.currentRange.location, length: NSMaxRange(next.currentRange) - current.currentRange.location)
                current = DiffHunk(baseRange: bRange, currentRange: cRange,
                                   deleted: baseText.substring(with: NSRange(location: bRange.location - base.baseRange.location, length: bRange.length)),
                                   inserted: curText.substring(with: NSRange(location: cRange.location - base.currentRange.location, length: cRange.length)))
            } else {
                out.append(current)
                current = next
            }
        }
        out.append(current)
        return out
    }

    // MARK: Accepter / refuser

    /// Accepter une modification : l'ancienne version l'intègre.
    public static func accept(_ hunk: DiffHunk, base: String) -> String {
        (base as NSString).replacingCharacters(in: hunk.baseRange, with: hunk.inserted)
    }

    /// Refuser une modification : la version actuelle revient au texte d'origine.
    public static func reject(_ hunk: DiffHunk, current: String) -> String {
        (current as NSString).replacingCharacters(in: hunk.currentRange, with: hunk.deleted)
    }
}
