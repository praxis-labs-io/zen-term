import AppKit

/// A declarative ephemeral command float. Everything variable about a float lives
/// here; the tool-float engine on `TabController` does the rest. Add a float by
/// adding a value to `ToolFloatCatalog.all` and one keybinding in `KeyInterceptor`.
struct ToolFloat: Equatable {
    let id: String  // stable id, e.g. "gitdash"
    let title: String  // command-palette title, e.g. "Open GitDash"
    let shortcut: String  // palette glyph string, e.g. "⌘⇧G" (display only)
    let icon: String  // dock icon: an SF Symbol name, or a bundled brand mark ("github", "git")
    let command: String  // runs as `$SHELL -l -i -c command` at the focused pane's cwd
    let widthFraction: CGFloat
    let heightFraction: CGFloat
    let requiresGitRepo: Bool
    let emptyGuard: EmptyGuard?
}

/// A pre-open probe: run `probe` at the focused cwd; if it exits 0 (nothing to
/// show), skip opening the float and surface `toast` instead.
struct EmptyGuard: Equatable {
    let probe: String
    let toast: ToastContent
}

/// The registered ephemeral tool floats. Adding an entry here (plus one
/// `KeyInterceptor` mapping) is all it takes to add a float — the dock button,
/// palette entry, git guard, and toggle behavior all derive from the spec.
enum ToolFloatCatalog {
    static let all: [ToolFloat] = [
        ToolFloat(
            id: "gitdash",
            title: "Open GitDash",
            shortcut: "⌘⇧G",
            icon: "github",
            command: "gd",  // `gh dash` — the GitHub PRs/issues TUI (resolved via the login shell)
            widthFraction: 0.85,
            heightFraction: 0.85,
            requiresGitRepo: false,  // gh dash spans all of GitHub — works outside a repo
            emptyGuard: nil)  // a GitHub dashboard isn't diff-state-gated
    ]

    static func byID(_ id: String) -> ToolFloat? { all.first { $0.id == id } }
}
