import AppKit
import EcritoireCore

/// Édition des versets d'un poème : le numéro `[n] ` est masqué, le curseur n'y entre jamais ;
/// Retour ouvre un nouveau verset numéroté, Effacer au début d'un verset le fusionne avec le précédent.
enum PoemCaret {
    struct VerseLine {
        let paragraph: NSRange   // sans le retour à la ligne final
        let markerEnd: Int
        let number: Int
    }

    static func contents(_ text: NSString, _ location: Int) -> NSRange {
        let para = text.paragraphRange(for: NSRange(location: min(location, text.length), length: 0))
        var end = NSMaxRange(para)
        while end > para.location, [0x0A, 0x0D, 0x2029].contains(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: para.location, length: end - para.location)
    }

    /// Verset numéroté qui contient `location` (hors en-tête).
    static func verse(at location: Int, in text: NSString, headerEnd: Int? = nil) -> VerseLine? {
        guard location >= (headerEnd ?? Poem.headerEnd(in: text)), location <= text.length else { return nil }
        let para = contents(text, location)
        guard let marker = Poem.marker(in: text.substring(with: para)) else { return nil }
        return VerseLine(paragraph: para, markerEnd: para.location + NSMaxRange(marker.range), number: marker.number)
    }

    /// Fin du texte du verset précédent (en sautant les lignes vides), nil s'il n'y en a pas.
    static func previousVerseEnd(before location: Int, in text: NSString, headerEnd: Int) -> Int? {
        var loc = location
        while loc > headerEnd {
            let para = contents(text, loc - 1)
            if para.length > 0 && !text.substring(with: para).trimmingCharacters(in: .whitespaces).isEmpty {
                return para.location >= headerEnd ? NSMaxRange(para) : nil
            }
            loc = para.location
        }
        return nil
    }

    /// Début du texte du verset suivant (après son numéro), nil s'il n'y en a pas.
    static func nextVerseStart(after location: Int, in text: NSString, headerEnd: Int) -> Int? {
        var loc = NSMaxRange(text.paragraphRange(for: NSRange(location: min(location, text.length), length: 0)))
        while loc < text.length {
            if let verse = verse(at: loc, in: text, headerEnd: headerEnd) { return verse.markerEnd }
            let para = contents(text, loc)
            if para.length > 0 && !text.substring(with: para).trimmingCharacters(in: .whitespaces).isEmpty { return para.location }
            loc = NSMaxRange(text.paragraphRange(for: NSRange(location: loc, length: 0)))
        }
        return nil
    }

    /// Position corrigée du curseur : jamais dans un numéro masqué ni sur une ligne vide entre deux versets.
    static func adjust(_ new: Int, from old: Int, in text: NSString) -> Int {
        let headerEnd = Poem.headerEnd(in: text)
        guard new >= headerEnd, new <= text.length, headerEnd > 0 || Poem.isPoem(text as String) else { return new }
        let backward = new < old
        let para = contents(text, new)
        if text.substring(with: para).trimmingCharacters(in: .whitespaces).isEmpty {
            // Ligne vide (masquée) : on passe au verset voisin dans le sens du déplacement.
            if backward, let end = previousVerseEnd(before: para.location, in: text, headerEnd: headerEnd) { return end }
            if let start = nextVerseStart(after: new, in: text, headerEnd: headerEnd) { return start }
            return previousVerseEnd(before: para.location, in: text, headerEnd: headerEnd) ?? new
        }
        if let verse = verse(at: new, in: text, headerEnd: headerEnd), new < verse.markerEnd {
            // Flèche gauche au début d'un verset : fin du verset précédent.
            if backward, old == verse.markerEnd, let end = previousVerseEnd(before: para.location, in: text, headerEnd: headerEnd) {
                return end
            }
            return verse.markerEnd
        }
        return new
    }
}

extension WritingTextView {
    /// Retour dans un verset : nouveau verset numéroté (le texte après le curseur passe dans le nouveau verset).
    override func insertNewline(_ sender: Any?) {
        let range = selectedRange()
        let text = string as NSString
        guard poemEditing, let verse = PoemCaret.verse(at: range.location, in: text), range.location >= verse.markerEnd else {
            super.insertNewline(sender)
            return
        }
        insertText("\n\n[\(verse.number + 1)] ", replacementRange: range)
    }

    /// Effacer au début d'un verset : fusion avec le verset précédent (numéro et ligne vide disparaissent ensemble).
    override func deleteBackward(_ sender: Any?) {
        let range = selectedRange()
        let text = string as NSString
        guard poemEditing, range.length == 0, let verse = PoemCaret.verse(at: range.location, in: text),
              range.location == verse.markerEnd else {
            super.deleteBackward(sender)
            return
        }
        let headerEnd = Poem.headerEnd(in: text)
        guard let end = PoemCaret.previousVerseEnd(before: verse.paragraph.location, in: text, headerEnd: headerEnd) else {
            NSSound.beep()
            return
        }
        setSelectedRange(NSRange(location: end, length: verse.markerEnd - end))
        super.deleteBackward(sender)
    }

    /// Supprimer à la fin d'un verset : le verset suivant le rejoint.
    override func deleteForward(_ sender: Any?) {
        let range = selectedRange()
        let text = string as NSString
        guard poemEditing, range.length == 0, let verse = PoemCaret.verse(at: range.location, in: text),
              range.location == NSMaxRange(verse.paragraph),
              let next = PoemCaret.nextVerseStart(after: range.location, in: text, headerEnd: Poem.headerEnd(in: text)) else {
            super.deleteForward(sender)
            return
        }
        setSelectedRange(NSRange(location: range.location, length: next - range.location))
        super.deleteForward(sender)
    }

    /// Recale les numéros des versets d'après leur position (après une insertion, une suppression, une fusion).
    /// Passe par les mêmes chemins qu'une frappe : annulable, commentaires et enregistrement suivent.
    func renumberVerses() {
        guard poemEditing, isEditable, !hasMarkedText(), let storage = textStorage else { return }
        let edits = Poem.renumberEdits(storage.string)
        guard !edits.isEmpty else { return }
        var selection = selectedRange()
        breakUndoCoalescing()
        for edit in edits { // de la fin vers le début : les positions restent valables
            guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { continue }
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
            didChangeText()
            let delta = (edit.replacement as NSString).length - edit.range.length
            if NSMaxRange(edit.range) <= selection.location {
                selection.location += delta
            } else if edit.range.location < selection.location {
                selection = NSRange(location: edit.range.location + (edit.replacement as NSString).length, length: 0)
            }
        }
        setSelectedRange(NSRange(location: min(selection.location, storage.length), length: min(selection.length, storage.length - min(selection.location, storage.length))))
    }
}
