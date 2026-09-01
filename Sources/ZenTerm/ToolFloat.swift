import AppKit

/// A declarative command float whose process lifetime is set by `persist:`. Everything variable
/// about a float lives here; the tool-float engine on `TabController` does the rest. Nearly every
/// float is user-defined in `~/.config/zen-term/config` (`float = …` lines), and for those the
/// `toggle` chord is the single source of truth, driving both the keybinding and the palette
/// glyph.
///
/// `ToolFloat.scratch` is the exception on both counts: it has no config line, and its `toggle` is
/// only the chord it ships with. A rebind moves the keymap entry and leaves the spec alone, so
/// nothing may render a glyph from `toggle` — `CommandCatalog.spec(for:)` reads the live keymap
/// and is the only correct source.
struct ToolFloat: Equatable {
    /// Stable identity, e.g. "open-gitdash" — `ToolFloatParser.slug(forTitle:)` of `title`, never
    /// authored and never stored in the config. It keys the live-float registry, the toolbar button
    /// map, and `toggle_float:<id>` keybinds, and it's how `ConfigWriter` finds a float's line. Identity
    /// tracks the title rather than `order` because a title is a property of the tool and changes only
    /// by deliberate rename, while order is a property of the list and changes routinely.
    let id: String
    /// Position in the toolbar, the palette, and Settings — the config `order:`, defaulting to the
    /// float's line order in the file. A `var` because reordering resequences a whole list of
    /// otherwise-untouched floats, and a `withOrder`-style copy helper would have to restate every
    /// other field, going stale the first time one is added.
    var order: Int
    let title: String  // the source of truth `id` is derived from, e.g. "Open GitDash"
    let icon: String  // toolbar icon: an SF Symbol name, or a bundled brand mark ("github", "git")
    /// Runs as `$SHELL -l -i -c command` at the focused pane's cwd. Empty means no program at
    /// all, just a shell — the built-in Scratch float, and the one thing a `float =` line can't
    /// spell, since `command:` is required there.
    let command: String
    /// A pinned working directory, or nil to follow the focused pane's cwd. For a tool that isn't
    /// about the directory you're in (a music player, an email client) or one that means a specific
    /// one (a notes scratchpad).
    let dir: URL?
    let widthFraction: CGFloat
    let heightFraction: CGFloat
    let requiresGitRepo: Bool

    /// How long a float's process lives — whether the instance survives dismissal, and what makes
    /// it stale. How MANY instances there are is the separate `scope` axis. The raw value is the
    /// config token; the case names avoid colliding with `Optional.none` (`.none`) and with the
    /// `dir:` field.
    enum Persistence: String {
        /// Terminate on dismiss; fresh spawn every open. Right for anything whose state goes stale
        /// (a file explorer, a scratch shell).
        case ephemeral = "none"
        /// One live instance per directory identity — reopening in the same directory restores
        /// it; a different one discards and respawns. With a pinned `dir:` the anchor is constant,
        /// so the instance simply never re-anchors. Right for directory-bound tools.
        case directory = "dir"
        /// One live instance for the window, anchored wherever it first opened and never
        /// re-anchored. Right for tools that aren't about the directory you're in at all (a
        /// process monitor, a music player, an email client).
        case window
    }

    /// Which container owns a float's live instance, orthogonal to `persist:` — scope says how many
    /// there are, `persist:` says how long each one lives.
    ///
    /// Deliberately not `RawRepresentable`: a raw value is exactly what would make this parseable,
    /// and `persist:tab` was cut before it shipped because daily driving showed tab scoping is the
    /// wrong axis for a tool. That verdict was about tools, which are about a directory or a
    /// machine. Scratch is a blank shell, which is about the work in front of you, so it is the one
    /// float that wants a tab.
    enum Scope { case window, tab }

    let persist: Persistence
    let toggle: Chord  // the config `key:` — binds the chord AND renders the palette glyph
    /// The config `toolbar:` — false hides the float's toolbar button. Visual only: the chord,
    /// palette entry, and persistence behave exactly as if the button were shown.
    var showsInToolbar: Bool = true
    /// Only meaningful for a float that registers — an `.ephemeral` one dies on dismiss either way.
    /// Last and defaulted so no config-built or test-built float has to name it.
    var scope: Scope = .window
}

extension ToolFloat {
    /// The one built-in float: a blank login shell over the tab, on ⌘;. A drawer's behavior in a
    /// float's shape — `scope: .tab` plus `persist: .window` gives it one live instance per tab
    /// that survives a dismissal and dies on `exit` or with its tab, which is what the two drawers
    /// do. The one deliberate difference: a tab change dismisses the card instead of carrying it.
    ///
    /// It has no `float =` line, so it is absent from Settings → Tools and is never written to the
    /// config. Only its chord is the user's to change, on the Shortcuts card.
    static let scratch = ToolFloat(
        id: "scratch",
        order: 0,  // inert: the built-ins lead the catalog and are never sorted with the user's
        title: "Scratch",
        icon: "square.fill.on.square",
        command: "",  // no program, just a shell — see `ToolFloatController.spawn`
        dir: nil,
        widthFraction: 0.7,
        heightFraction: 0.6,
        requiresGitRepo: false,
        persist: .window,
        // The DEFAULT chord, not the live one. Nothing may render a shortcut from this: a rebind
        // only moves the keymap entry, so every glyph goes through `CommandCatalog.spec(for:)`.
        toggle: Chord(command: true, key: ";"),
        showsInToolbar: true,
        scope: .tab)

    static let builtInIDs: Set<String> = [scratch.id]

    static func isBuiltIn(_ id: String) -> Bool { builtInIDs.contains(id) }
}

/// The active tool floats: the one built-in, then the ones the user declared in their config.
/// Scratch is the only built-in, and it lives here rather than in `GeneralConfig` so a fresh
/// install still writes nothing to disk. The toolbar button, palette entry, git guard, and
/// toggle behavior all derive from a spec, built-in or not.
enum ToolFloatCatalog {
    static let builtIns: [ToolFloat] = [.scratch]

    static var userDefined: [ToolFloat] { GeneralConfig.current.floats }

    static var all: [ToolFloat] { builtIns + userDefined }

    static func byID(_ id: String) -> ToolFloat? { all.first { $0.id == id } }
}
