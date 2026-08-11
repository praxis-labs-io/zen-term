/// Builds the text a diff comment sends into a terminal. Pure, so the whole message is
/// assertable without a surface.
///
/// The message is the note with the reference as its first token, and nothing else: no preamble, no
/// mention of ZenTerm. What lands in the agent's input should read like something the user typed.
enum DiffComment {
    /// `<reference> <note>`, or the bare reference when there's no note (select, ⏎, ⏎ puts just the
    /// line range in the input).
    ///
    /// `removedLines` are appended under a label when the selection is removals-only or the file is
    /// deleted: the reference points at a line the agent can still read, but removed text is in no
    /// working-tree file, so the only way it reaches the agent is by riding along here. Safe to send
    /// multi-line because `TerminalSurface.paste` is bracketed: it arrives as one block, not as a run
    /// of Enter presses.
    static func message(reference: String, note: String, removedLines: [String] = []) -> String {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = note.isEmpty ? reference : "\(reference) \(note)"
        guard !removedLines.isEmpty else { return head }
        return head + "\n\nRemoved lines:\n" + removedLines.joined(separator: "\n")
    }
}
