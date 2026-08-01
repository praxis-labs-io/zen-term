import AppKit
import AppLog
import TerminalKit

/// Scroll mode: a sticky keyboard mode over one focused terminal, where vim keys move the
/// viewport through the scrollback instead of reaching the shell (ZEN-330).
///
/// It exists because the keys that should scroll a buffer are the ones the shell already owns.
/// `j`, `k`, `⌃d` and `⌃u` cannot be reserved chords without taking them from every program
/// running in every pane, and libghostty's own ⌘Home/⌘PageUp defaults are fn-chords on a laptop
/// that no menu or palette ever mentions. A mode borrows the keys for as long as it is up and
/// gives them back on the way out.
///
/// The mode is per window and targets whichever panel holds unified focus at the moment it
/// opens. It does not follow focus afterward: moving focus ends it, because a scroll mode
/// pointing at a pane you are no longer looking at is a trap rather than a feature.
@MainActor
final class ScrollModeController {
    /// One move through the buffer, decoded from a keystroke. Separate from `TerminalScroll` so
    /// the exits and the `g` prefix (neither of which is a scroll) live in the same decode.
    enum Command: Equatable {
        case scroll(TerminalScroll)
        /// First `g` of `gg`. Arms the prefix; a second `g` tops out.
        case pendingTop
        case exit
    }

    /// Whether the mode is up. The single source of truth for both the key hook and the header.
    private(set) var isActive = false

    private weak var surface: (AnyObject & TerminalSurface)?
    private weak var panel: PanelHostView?
    private var sawG = false

    /// Fires whenever the mode opens or closes, so the window can install and remove its key
    /// hook without this type reaching back into `KeyInterceptor`.
    var onActiveChanged: ((Bool) -> Void)?

    // MARK: lifecycle

    /// Enter the mode over `target`, or do nothing if it is already up over the same panel.
    ///
    /// Entering scrolls nothing. A reader who opened the mode by accident sees only the header
    /// appear, and `q` puts it back.
    func begin(surface: AnyObject & TerminalSurface, panel: PanelHostView) {
        guard !isActive else { return }
        self.surface = surface
        self.panel = panel
        sawG = false
        isActive = true
        Log.info("scroll mode entered", category: .panes)
        updateHeader(position: nil)
        onActiveChanged?(true)
    }

    /// Leave the mode and take the header down.
    ///
    /// Idempotent, and deliberately so: every teardown trigger (focus moved, pane closed, tab
    /// switched, window resigned key, surface exited) calls this without first checking whether
    /// one of the others got there first. A sticky mode whose retraction path is conditional is
    /// how you end up with a header over a pane that no longer exists.
    func end() {
        guard isActive else { return }
        isActive = false
        sawG = false
        panel?.modeMeta = nil
        panel = nil
        surface = nil
        Log.info("scroll mode left", category: .panes)
        onActiveChanged?(false)
    }

    /// Whether `s` is the surface the mode is currently driving, so a caller holding a surface
    /// (a pane that just exited) can end only its own mode.
    func isDriving(_ s: AnyObject) -> Bool { surface === (s as AnyObject) }

    // MARK: keys

    /// Handle one `keyDown` while the mode is up. Returns whether it was consumed.
    ///
    /// Every key is consumed while the mode is live, mapped or not. A mode that passed its
    /// misses through would drop a stray `x` into the shell behind it, which is a worse failure
    /// than a keystroke that does nothing.
    func handle(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        guard let command = Self.command(for: event, afterG: sawG) else {
            sawG = false
            return true
        }
        switch command {
        case .pendingTop:
            sawG = true
        case .exit:
            end()
        case .scroll(let move):
            sawG = false
            surface?.scroll(move)
        }
        return true
    }

    /// Decode a `keyDown` into a scroll-mode command, or nil for a key the mode does not map.
    ///
    /// Pure and static so the whole keymap is testable without a window or an event loop, the
    /// same seam `DiffPaneTable.vimKey(for:)` uses. `afterG` is the `gg` prefix, passed in rather
    /// than read off the instance for the same reason.
    ///
    /// Shiftedness comes from the modifier flags, never from the character's case: Caps Lock
    /// uppercases too, so reading case would make a single `g` jump to the top whenever Caps Lock
    /// was on, and turn `j` into a dead key.
    static func command(for event: NSEvent, afterG: Bool) -> Command? {
        let held = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // ⌃d/⌃u/⌃f/⌃b are the vim half- and full-page keys. Match Control exactly so ⌘⌃d and
        // friends fall through to whoever owns them.
        if held == .control {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "d": return .scroll(.pageFraction(0.5))
            case "u": return .scroll(.pageFraction(-0.5))
            case "f": return .scroll(.pageFraction(1))
            case "b": return .scroll(.pageFraction(-1))
            default: return nil
            }
        }
        // Everything else is bare or shifted. ⌘ and ⌥ belong to another handler.
        guard held.isSubset(of: .shift) else { return nil }
        if event.keyCode == Self.escapeKeyCode { return .exit }
        let shift = held.contains(.shift)
        switch (event.charactersIgnoringModifiers?.lowercased() ?? "", shift) {
        case ("j", false), (Self.downArrow, false): return .scroll(.lines(1))
        case ("k", false), (Self.upArrow, false): return .scroll(.lines(-1))
        case (" ", false): return .scroll(.pageFraction(1))
        case ("g", false): return afterG ? .scroll(.top) : .pendingTop
        case ("g", true): return .scroll(.bottom)
        case ("[", false): return .scroll(.prompt(-1))
        case ("]", false): return .scroll(.prompt(1))
        case ("q", false), ("i", false): return .exit
        default: return nil
        }
    }

    private static let escapeKeyCode: UInt16 = 53
    /// Arrow keys arrive as private-use scalars in `charactersIgnoringModifiers`, matched here so
    /// the arrows work without a second keyCode branch.
    private static let upArrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)

    // MARK: the header

    /// Refresh the indicator from a live scroll position. Called on every `SCROLLBAR` report for
    /// the driven surface, so the count tracks output as well as keys.
    func report(position: TerminalScrollPosition, from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        updateHeader(position: position)
    }

    private func updateHeader(position: TerminalScrollPosition?) {
        panel?.modeMeta = PanelMeta(title: Self.headerTitle(position), action: .toggleScrollMode)
    }

    /// What the pane header reads. "Scroll" alone until the terminal has reported a position,
    /// because a count invented before the first report would be wrong rather than absent.
    static func headerTitle(_ position: TerminalScrollPosition?) -> String {
        guard let position else { return "Scroll" }
        let below = position.linesBelow
        if below == 0 { return "Scroll: at bottom" }
        return "Scroll: \(Self.lineCount.string(from: NSNumber(value: below)) ?? "\(below)") below"
    }

    private static let lineCount: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
