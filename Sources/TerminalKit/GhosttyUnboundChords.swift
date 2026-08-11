/// The libghostty binds ZenTerm takes back, as ghostty trigger spellings.
///
/// libghostty's keymap stays live underneath the chrome's, so every chord here either duplicates a
/// ZenTerm action in ghostty's vocabulary or eats the key for an action our apprt never
/// implements. Unbinding hands the chord to the program in the pane.
///
/// **This is a decision list, not a derived one.** `BackendShadowSweepTests` keeps it honest by
/// walking the typeable chord space against a live surface and failing when the surviving shadow
/// is not exactly `kept`.
enum GhosttyUnboundChords {
    /// Emitted as `keybind = <trigger>=unbind` into the generated config. Some actions are bound
    /// twice under different spellings and both have to go: `increase_font_size` sits on `=` and
    /// `+`, and `goto_tab` on both the physical `digit_N` key and the `unicode` one.
    static let triggers: [String] =
        tabs + splitsAndPanes + windowsAndTabs + appLevel + unimplemented + scrollingAndFinding
        + screenAndPrompts

    /// `goto_tab` and `last_tab`, which ZenTerm holds as select_tab_1…9. ⌘9 is `last_tab` and
    /// carries only the `unicode` spelling, since ghostty's loop stops at 8, so a `cmd+digit_9`
    /// line would match nothing and a dead unbind is invisible to the sweep.
    private static let tabs: [String] =
        (1...8).flatMap { ["cmd+\($0)", "cmd+digit_\($0)"] } + ["cmd+9"]

    /// ghostty's split model, which ZenTerm holds as panes: nav, resize, and the two splits. ⌘[
    /// and ⌘] are the exception and stay tabs.
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

    /// Bound in libghostty, and dead: each of these reaches an apprt callback ZenTerm does not
    /// implement, so the key is swallowed and nothing happens. ⌃⌘F stays here rather than moving
    /// to Fill Screen, because it is macOS's native fullscreen chord and Fill Screen is a maximize.
    private static let unimplemented: [String] = [
        "cmd+ctrl+=",
        "cmd+opt+w", "cmd+shift+w", "cmd+shift+opt+w",
        "cmd+enter", "cmd+ctrl+f",
        "cmd+opt+i",
        "cmd+z", "cmd+shift+z", "cmd+shift+t",
    ]

    /// Scrolling the viewport and stepping a search, which ZenTerm named and kept on
    /// ghostty's own chords. Nothing a user presses changes, and the behavior is ours to describe
    /// in Settings and to rebind.
    private static let scrollingAndFinding: [String] = [
        "cmd+home", "cmd+end", "cmd+page_up", "cmd+page_down",
        "cmd+g", "cmd+shift+g", "cmd+e",
    ]

    /// The screen, the selection and the prompt marks, each of which the seam grew a call for.
    /// ⌘K, ⌘J and ⌘⇧J are the chrome's Clear Screen, Scroll to Selection and Write Screen to File
    /// on ghostty's own chords, so the unbind hands each to the chrome rather than the program.
    ///
    /// ghostty binds write-screen-file three times, to copy, paste and open the path. ZenTerm
    /// names that behavior once, so the other two go to the program.
    private static let screenAndPrompts: [String] = [
        "cmd+k", "cmd+j", "cmd+a",
        "cmd+arrow_up", "cmd+arrow_down", "cmd+shift+arrow_up", "cmd+shift+arrow_down",
        "cmd+shift+v",
        "cmd+shift+j", "cmd+shift+ctrl+j", "cmd+shift+opt+j",
    ]

    /// What libghostty is left holding, and what the sweep asserts survives.
    ///
    /// All of one kind: terminal encoding rather than chrome action. A keystroke that turns into
    /// bytes for the program is not a shortcut, so these stay with the backend. ⌘⌫ is `backspace`
    /// because ghostty's `delete` is the forward-delete key.
    static let kept: [String] = [
        "cmd+arrow_left", "cmd+arrow_right", "cmd+backspace",
        "opt+arrow_left", "opt+arrow_right",
        "shift+arrow_left", "shift+arrow_right", "shift+arrow_up", "shift+arrow_down",
        "shift+home", "shift+end", "shift+page_up", "shift+page_down",
    ]
}
