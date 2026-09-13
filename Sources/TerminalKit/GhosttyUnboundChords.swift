// libghostty binds ZenTerm takes back for the pane's program. Hand-kept; `BackendShadowSweepTests` checks it.
enum GhosttyUnboundChords {
    // Some actions bind twice (`=` and `+`, `digit_N` and `unicode`), and both spellings must go.
    static let triggers: [String] =
        tabs + splitsAndPanes + windowsAndTabs + appLevel + unimplemented + scrollingAndFinding
        + screenAndPrompts

    // ⌘9 is `last_tab` with only the `unicode` spelling; a `cmd+digit_9` unbind would match nothing.
    private static let tabs: [String] =
        (1...8).flatMap { ["cmd+\($0)", "cmd+digit_\($0)"] } + ["cmd+9"]

    private static let splitsAndPanes: [String] = [
        "cmd+[", "cmd+]",
        "cmd+opt+arrow_left", "cmd+opt+arrow_right", "cmd+opt+arrow_up", "cmd+opt+arrow_down",
        "cmd+ctrl+arrow_left", "cmd+ctrl+arrow_right", "cmd+ctrl+arrow_up", "cmd+ctrl+arrow_down",
        "cmd+d", "cmd+shift+d",
        "cmd+w",
        "cmd+shift+enter",
    ]

    private static let windowsAndTabs: [String] = [
        "cmd+shift+[", "cmd+shift+]",
        "ctrl+tab", "ctrl+shift+tab",
        "cmd+t", "cmd+n",
    ]

    private static let appLevel: [String] = [
        "cmd+=", "cmd++", "cmd+-", "cmd+0",
        "cmd+f", "cmd+shift+f",
        "cmd+,", "cmd+shift+,",
        "cmd+shift+p",
        "cmd+q", "cmd+c", "cmd+v",
        "escape",
    ]

    // Each reaches an apprt callback ZenTerm does not implement, so the key is swallowed.
    private static let unimplemented: [String] = [
        "cmd+ctrl+=",
        "cmd+opt+w", "cmd+shift+w", "cmd+shift+opt+w",
        "cmd+enter", "cmd+ctrl+f",
        "cmd+opt+i",
        "cmd+z", "cmd+shift+z", "cmd+shift+t",
    ]

    private static let scrollingAndFinding: [String] = [
        "cmd+home", "cmd+end", "cmd+page_up", "cmd+page_down",
        "cmd+g", "cmd+shift+g", "cmd+e",
    ]

    private static let screenAndPrompts: [String] = [
        "cmd+k", "cmd+j", "cmd+a",
        "cmd+arrow_up", "cmd+arrow_down", "cmd+shift+arrow_up", "cmd+shift+arrow_down",
        "cmd+shift+v",
        "cmd+shift+j", "cmd+shift+ctrl+j", "cmd+shift+opt+j",
    ]

    // Terminal encodings, not chrome actions. ⌘⌫ is `backspace` because ghostty's `delete` is forward-delete.
    static let kept: [String] = [
        "cmd+arrow_left", "cmd+arrow_right", "cmd+backspace",
        "opt+arrow_left", "opt+arrow_right",
        "shift+arrow_left", "shift+arrow_right", "shift+arrow_up", "shift+arrow_down",
        "shift+home", "shift+end", "shift+page_up", "shift+page_down",
    ]
}
