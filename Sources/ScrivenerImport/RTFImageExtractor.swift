import Foundation

/// Sort les images `\pict` d'un RTF (que le lecteur RTF de Cocoa ignore) et les remplace
/// par un marqueur texte `ECRITOIREIMAGE<n>FIN`, retrouvé ensuite lors de la conversion en Markdown.
enum RTFImageExtractor {
    struct Picture {
        let data: Data
        let ext: String
    }

    static func placeholder(_ index: Int) -> String { "ECRITOIREIMAGE\(index)FIN" }
    static let placeholderPattern = #"ECRITOIREIMAGE(\d+)FIN"#

    static func extract(from rtf: Data) -> (rtf: Data, pictures: [Picture?]) {
        var bytes = [UInt8](rtf)
        guard contains(bytes, "\\pict") else { return (rtf, []) }
        // 1. Les variantes de repli ({\nonshppict …}) font doublon : on les supprime.
        bytes = replaceGroups(in: bytes, starting: "{\\nonshppict") { _ in [] }
        var pictures: [Picture?] = []
        let replace: ([UInt8]) -> [UInt8] = { group in
            pictures.append(decodePicture(group))
            return Array(" \(placeholder(pictures.count - 1)) ".utf8)
        }
        // 2. {\*\shppict{\pict …}} puis les {\pict …} isolés.
        bytes = replaceGroups(in: bytes, starting: "{\\*\\shppict", replace)
        bytes = replaceGroups(in: bytes, starting: "{\\pict", replace)
        return (Data(bytes), pictures)
    }

    private static func contains(_ bytes: [UInt8], _ needle: String) -> Bool {
        find(Array(needle.utf8), in: bytes, from: 0) != nil
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
        var i = start
        let last = bytes.count - needle.count
        let first = needle[0]
        while i <= last {
            if bytes[i] == first {
                var j = 1
                while j < needle.count && bytes[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// Remplace chaque groupe RTF commençant par `prefix` (accolades équilibrées) par le résultat de `transform`.
    private static func replaceGroups(in bytes: [UInt8], starting prefix: String, _ transform: ([UInt8]) -> [UInt8]) -> [UInt8] {
        let needle = Array(prefix.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var cursor = 0
        while let start = find(needle, in: bytes, from: cursor) {
            // Le mot de contrôle doit se terminer là (\pict et non \pictscaled…).
            let after = start + needle.count
            if after < bytes.count, isLetter(bytes[after]) {
                out.append(contentsOf: bytes[cursor..<after])
                cursor = after
                continue
            }
            var depth = 0
            var end = start
            var k = start
            while k < bytes.count {
                let b = bytes[k]
                if b == UInt8(ascii: "\\") { k += 2; continue }
                if b == UInt8(ascii: "{") { depth += 1 }
                if b == UInt8(ascii: "}") {
                    depth -= 1
                    if depth == 0 { end = k; break }
                }
                k += 1
            }
            guard depth == 0, end > start else { break }
            out.append(contentsOf: bytes[cursor..<start])
            out.append(contentsOf: transform(Array(bytes[start...end])))
            cursor = end + 1
        }
        out.append(contentsOf: bytes[cursor...])
        return out
    }

    private static func isLetter(_ b: UInt8) -> Bool {
        (b >= 97 && b <= 122) || (b >= 65 && b <= 90)
    }

    /// Décode le premier \pict du groupe : type (\pngblip, \jpegblip) et données hexadécimales.
    private static func decodePicture(_ group: [UInt8]) -> Picture? {
        guard let pict = find(Array("\\pict".utf8), in: group, from: 0) else { return nil }
        let text = String(decoding: group[pict...], as: UTF8.self)
        let ext: String
        if text.contains("\\pngblip") { ext = "png" }
        else if text.contains("\\jpegblip") { ext = "jpg" }
        else { return nil } // WMF/EMF/PICT : non pris en charge
        // Les données sont la dernière longue suite de chiffres hexadécimaux du groupe.
        var data = Data()
        var current = Data()
        var high: UInt8? = nil
        var runLength = 0
        var i = pict
        var skipControlWord = false
        while i < group.count {
            let b = group[i]
            if b == UInt8(ascii: "\\") {
                skipControlWord = true
                i += 1
                continue
            }
            if skipControlWord {
                if isLetter(b) || (b >= 48 && b <= 57) || b == UInt8(ascii: "-") { i += 1; continue }
                skipControlWord = false
            }
            if let v = hexValue(b) {
                if let h = high { current.append(h << 4 | v); high = nil } else { high = v }
                runLength += 1
            } else if b == 10 || b == 13 || b == 32 {
                // espaces : autorisés dans les données
            } else {
                if runLength > 64 && current.count > data.count { data = current }
                current = Data(); high = nil; runLength = 0
            }
            i += 1
        }
        if current.count > data.count { data = current }
        return data.count > 32 ? Picture(data: data, ext: ext) : nil
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 48...57: return b - 48
        case 97...102: return b - 87
        case 65...70: return b - 55
        default: return nil
        }
    }
}
