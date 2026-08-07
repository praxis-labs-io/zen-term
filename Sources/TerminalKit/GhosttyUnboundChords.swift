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
    /// Some actions are bound twice under different spellings and both have to go:
    /// `increase_font_size` sits on `=` and on `+`, and `goto_tab` on both the physical `digit_N`
    /// key and the `unicode` one, so an AZERTY layout reaches it too.
    static let triggers: [String] =
        tabs + splitsAndPanes + windowsAndTabs + appLevel + unimplemented + scrollingAndFinding
        + screenAndPrompts

    /// `goto_tab` and `last_tab`, which ZenTerm holds as select_tab_1…9.
    ///
    /// ⌘9 is `last_tab` rather than the ninth `goto_tab`, and it carries only the `unicode`
    /// spelling: ghostty's loop stops at 8. A `cmd+digit_9` line here would match nothing, and a
    /// dead unbind is invisible to the sweep.
    private static let tabs: [String] =
        (1...8).flatMap { ["cmd+\($0)", "cmd+digit_\($0)"] } + ["cmd+9"]

    /// ghostty's split model, which ZenTerm holds as panes: nav, resize, and the two splits.
    ///
    /// The chrome answers most of these itself: ⌘D and ⌘⇧D split, ⌘⌥arrows focus a pane, ⌘⌃arrows
    /// resize one, ⌘⇧⏎ is Focus Mode. ⌘[ and ⌘] are the exception and stay tabs.
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

    /// App-level chords ZenTerm answers itself, or the menu bar does. ⌘F is Find, matching ghostty.
    /// ⌘⇧F is its `end_search` and stays unbound: our find bar closes on the same ⌘F that opened it.
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
    /// separate change. ⌘⏎ is one: it is Fill Screen now. ⌃⌘F is ghostty's second spelling of the
    /// same action and stays here, because it is macOS's native fullscreen chord and Fill Screen is
    /// a maximize.
    private static let unimplemented: [String] = [
        "cmd+ctrl+=",
        "cmd+opt+w", "cmd+shift+w", "cmd+shift+opt+w",
        "cmd+enter", "cmd+ctrl+f",
        "cmd+opt+i",
        "cmd+z", "cmd+shift+z", "cmd+shift+t",
    ]

    /// Scrolling the viewport and stepping a search, which ZenTerm named in ZEN-367 and kept on
    /// ghostty's own chords. Nothing a user presses changes, and the behavior is ours to describe
    /// in Settings and to rebind.
    private static let scrollingAndFinding: [String] = [
        "cmd+home", "cmd+end", "cmd+page_up", "cmd+page_down",
        "cmd+g", "cmd+shift+g", "cmd+e",
    ]

    /// The screen, the selection and the prompt marks, which ZenTerm named in ZEN-369. The seam
    /// grew for each: clear the screen, select everything, scroll to the selection, jump a prompt,
    /// write the screen to a file. Paste-the-selection is the chrome's own, built from the
    /// selection it already reads.
    ///
    /// ⌘K, ⌘J and ⌘⇧J are Clear Screen, Scroll to Selection and Write Screen to File here too, on
    /// ghostty's own chords, so the unbind hands each to the chrome rather than to the program.
    ///
    /// ghostty binds write-screen-file three times, on ⌘⇧⌃J to copy the path, ⌘⇧J to paste it and
    /// ⌘⇧⌥J to open the file. One behavior, and ZenTerm names it once: the other two go to the
    /// program.
    private static let screenAndPrompts: [String] = [
        "cmd+k", "cmd+j", "cmd+a",
        "cmd+arrow_up", "cmd+arrow_down", "cmd+shift+arrow_up", "cmd+shift+arrow_down",
        "cmd+shift+v",
        "cmd+shift+j", "cmd+shift+ctrl+j", "cmd+shift+opt+j",
    ]

    /// What libghostty is left holding, and what the sweep asserts survives.
    ///
    /// All of one kind now: terminal encoding rather than chrome action. A keystroke that turns
    /// into bytes for the program is not a shortcut, so these stay with the backend for good, and
    /// the list is finished rather than waiting on the next ticket.
    ///
    /// ⌘⌫ is `backspace`: ghostty's `delete` is the forward-delete key, so spelling it that way
    /// would emit an unbind matching nothing the day this moves.
    static let kept: [String] = [
        "cmd+arrow_left", "cmd+arrow_right", "cmd+backspace",
        "opt+arrow_left", "opt+arrow_right",
        "shift+arrow_left", "shift+arrow_right", "shift+arrow_up", "shift+arrow_down",
        "shift+home", "shift+end", "shift+page_up", "shift+page_down",
    ]
}
