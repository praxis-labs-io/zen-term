/// A problem found while loading the config, carried on `GeneralConfig` so a surface can show it
/// in place instead of the user's only clue being an `NSLog` nobody reads.
///
/// Only `.keybind` diagnostics are collected today (ZEN-142). Every other bad-config path —
/// invalid ints, bad enum values, malformed float lines — still logs and silently falls back;
/// collecting and rendering those is ZEN-154, and is additive to this type.
struct ConfigDiagnostic: Equatable {
    enum Severity: Equatable {
        /// The config asked for something impossible and the app carried on without it.
        case warning
    }

    /// Which surface can render this in place, and what it's about. The associated value names the
    /// subject so a section can match a diagnostic to the row that owns it.
    enum Scope: Equatable {
        /// The action left with no shortcut. Its Settings row carries the message.
        case keybind(KeyInterceptor.ReservedChord)
    }

    var severity: Severity
    var scope: Scope
    /// Written in the *config file's* vocabulary (`⌘⇧\ went to toggle_zoom`), not the UI's, so it
    /// names the exact token to grep for in the file the user has to edit to fix it.
    var message: String
}
