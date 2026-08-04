/// The libghostty binds ZenTerm takes back, as ghostty trigger spellings (ZEN-365).
///
/// The chrome resolves its keymap ahead of the responder chain and passes on everything it does
/// not claim, so libghostty's keymap is live underneath ours the whole time. Every chord here is
/// one ZenTerm already has an action for, or one whose action our apprt never implements — so the
/// bind either duplicates the chrome in ghostty's own vocabulary, or eats the key and does nothing.
/// Unbinding hands the chord to the program in the pane, which is where it belonged.
///
/// **This is a decision list, not a derived one.** It says which of libghostty's binds we want,
/// and the only way to keep it honest is to measure: `BackendShadowSweepTests` walks the whole
/// typeable chord space against a live surface and fails when the surviving shadow is not exactly
/// `kept`. A pin bump that adds a bind, or an unbind spelling that stops matching, turns it red.
enum GhosttyUnboundChords {
    /// Emitted as `keybind = <trigger>=unbind` into the generated config.
    ///
    /// Some actions are bound twice under different spellings and both have to go: the digits
    /// carry a physical `digit_N` bind alongside the `unicode` one, and `increase_font_size` is
    /// bound on both `=` and `+`.
    static let triggers: [String] = tabs + splitsAndPanes + windowsAndTabs + appLevel + unimplemented

    /// `goto_tab` and `last_tab`, which ZenTerm holds as select_tab_1…9.
    private static let tabs: [String] =
        (1...9).flatMap { ["cmd+\($0)", "cmd+digit_\($0)"] }

    /// ghostty's split model, which ZenTerm holds as panes: nav, resize, and the two splits.
    private static let splitsAndPanes: [String] = [
        "cmd+[", "cmd+]",
        "cmd+opt+arrow_left", "cmd+opt+arrow_right", "cmd+opt+arrow_up", "cmd+opt+arrow_down",
        "cmd+ctrl+arrow_left", "cmd+ctrl+arrow_right", "cmd+ctrl+arrow_up", "cmd+ctrl+arrow_down",
        "cmd+d", "cmd+shift+d",
        "cmd+w",
        "cmd+shift+enter",
    ]

    /// ghostty's tab and window model, which ZenTerm holds as tabs and windows.
    private static let windowsAndTabs: [String] = [
        "cmd+shift+[", "cmd+shift+]",
        "ctrl+tab", "ctrl+shift+tab",
        "cmd+t", "cmd+n",
    ]

    /// App-level chords ZenTerm answers itself, or the menu bar does.
    private static let appLevel: [String] = [
        "cmd+=", "cmd++", "cmd+-", "cmd+0",
        "cmd+f", "cmd+shift+f",
        "cmd+,", "cmd+shift+,",
        "cmd+shift+p",
        "cmd+q", "cmd+c", "cmd+v",
        "escape",
    ]

    /// Bound in libghostty, and dead: every one of these actions reaches an apprt callback ZenTerm
    /// does not implement, so the key is swallowed and nothing happens. Safe to unbind before the
    /// matching ZenTerm feature exists, because binding our own action to the chord later is a
    /// separate change.
    private static let unimplemented: [String] = [
        "cmd+ctrl+=",
        "cmd+opt+w", "cmd+shift+w", "cmd+shift+opt+w",
        "cmd+enter", "cmd+ctrl+f",
        "cmd+opt+i",
        "cmd+z", "cmd+shift+z", "cmd+shift+t",
    ]

    /// What libghostty is left holding, and what the sweep asserts survives.
    ///
    /// Two kinds. The first is behavior ZenTerm has no action for yet, kept bound so nothing is
    /// lost before it is named. The second is terminal encoding rather than chrome action: those
    /// stay with the backend for good, because a keystroke that turns into bytes for the program
    /// is not a shortcut.
    static let kept: [String] = [
        // Not yet named by ZenTerm.
        "cmd+k", "cmd+j", "cmd+a",
        "cmd+home", "cmd+end", "cmd+page_up", "cmd+page_down",
        "cmd+arrow_up", "cmd+arrow_down", "cmd+shift+arrow_up", "cmd+shift+arrow_down",
        "cmd+g", "cmd+shift+g", "cmd+e",
        "cmd+shift+ctrl+j", "cmd+shift+opt+j", "cmd+shift+j",
        "cmd+shift+v",
        // Encodings, kept for good.
        "cmd+arrow_left", "cmd+arrow_right", "cmd+delete",
        "opt+arrow_left", "opt+arrow_right",
        "shift+arrow_left", "shift+arrow_right", "shift+arrow_up", "shift+arrow_down",
        "shift+home", "shift+end", "shift+page_up", "shift+page_down",
    ]
}
