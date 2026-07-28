import CoreGraphics

/// The terminal font size this session is running at, in points — what ⌘+ / ⌘- / ⌘0 move (ZEN-224).
///
/// App-global rather than per-window, and deliberately so: the ticket is that a size change reached
/// one pane. A per-window value would leave the same bug one level up, where a second window kept
/// its own size.
///
/// Session-scoped: it starts at the config's `font-size` and dies with the process, so `~/.config`
/// stays the thing the user edits and this stays the thing they nudge. Nothing writes it back.
///
/// **This is the only size a running surface wears.** libghostty marks a surface `font_size_adjusted`
/// the first time it is given an explicit size and then leaves it out of config reloads, so a
/// surface that has been stepped no longer follows `Theme.current.terminal.fontSize` at all. The
/// chrome therefore re-pushes `points` after every appearance re-apply rather than expecting the
/// theme's size to land — see `WindowController`'s `.configDidChange` observer.
enum SessionFontSize {
    /// The floor and ceiling, matching the range the config parser clamps `font-size` to, so one
    /// concept has one range whichever way the user reaches it.
    static let range: ClosedRange<CGFloat> = 6...32

    /// The size every terminal surface is currently wearing.
    private(set) static var points: CGFloat = GeneralConfig.builtIn.fontSize

    /// The config `font-size` `points` was last seeded from — how a *changed* base is told from an
    /// unchanged one. `ConfigChange.theme` can't answer that: it subsumes font family, size and
    /// every color, so recoloring the theme would otherwise throw away a size the user had stepped.
    private static var base: CGFloat = GeneralConfig.builtIn.fontSize

    /// Adopt the config's size, discarding any step. Called at launch, once the config is resolved.
    static func seed(from config: GeneralConfig) {
        base = config.fontSize
        points = config.fontSize
    }

    /// Re-seed only if the config's `font-size` actually moved, and report whether it did.
    ///
    /// The Settings font-size row stays authoritative: setting it to 18 while stepped to 20 lands on
    /// 18, rather than the row appearing dead because libghostty is ignoring config reloads for
    /// every surface the user has stepped. A theme or font-family edit leaves the stepped size alone.
    @discardableResult
    static func reseedIfBaseChanged(from config: GeneralConfig) -> Bool {
        guard config.fontSize != base else { return false }
        seed(from: config)
        return true
    }

    /// Step by whole points — libghostty's own increment, so ⌘+ / ⌘- feel exactly as they did when
    /// libghostty handled them per surface. Clamped; stepping at a bound is a no-op.
    static func step(by delta: CGFloat) {
        points = min(max(points + delta, range.lowerBound), range.upperBound)
    }

    /// Back to the config's size.
    static func reset() { points = base }

    /// The size as the card shows it: whole points read as "16pt", and a config that asks for 14.5
    /// keeps its half rather than being rounded into a lie.
    static var display: String {
        points == points.rounded()
            ? "\(Int(points))pt"
            : "\(points)pt"
    }
}
