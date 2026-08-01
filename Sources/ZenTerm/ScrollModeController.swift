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
        /// A one-line step, which moves the cursor rather than the viewport until the cursor is
        /// pinned at an edge. Kept apart from `.scroll(.lines(±1))` because that distinction is
        /// the whole difference between a cursor and a scrollbar.
        case step(Int)
        /// First `g` of `gg`. Arms the prefix; a second `g` tops out.
        case pendingTop
        case exit
    }

    /// Whether the mode is up. The single source of truth for both the key hook and the header.
    private(set) var isActive = false

    private weak var surface: (AnyObject & TerminalSurface)?
    private weak var panel: PanelHostView?
    private var sawG = false

    /// The viewport row the cursor sits on, 0 at the top. Viewport-relative rather than absolute
    /// in the buffer, so it survives output arriving underneath without any bookkeeping: the row
    /// on screen is the row you are looking at.
    private(set) var cursorRow = 0

    /// A prompt jump has been asked for and we are waiting to hear whether the viewport moved.
    /// See the `.prompt` case in `handle` for why the cursor cannot be placed at the time of the
    /// keystroke.
    private var awaitingPromptLanding = false

    /// Fires whenever the mode opens or closes, so the window can install and remove its key
    /// hook without this type reaching back into `KeyInterceptor`.
    var onActiveChanged: ((Bool) -> Void)?

    /// Say a prompt jump had nowhere to go, matching pane nav's rule that every dead nav attempt
    /// speaks rather than silently doing nothing.
    var onRequestToast: ((ToastContent) -> Void)?

    /// The last position the surface reported, kept so a dead prompt jump can be recognised
    /// before it is attempted. Nil until the first report arrives.
    private var lastPosition: TerminalScrollPosition?
    private var lastDeadJumpAt: Date?

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
        // Open on the terminal's own cursor, which is the last written line. The bottom of the
        // viewport is the bottom of the pane, and on a half-filled screen that is empty space
        // below everything there is to read.
        cursorRow = surface.cursorRow ?? max((surface.cellMetrics?.rows ?? 1) - 1, 0)
        Log.info("scroll mode entered", category: .panes)
        updateHeader(position: nil)
        refreshCursor()
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
        awaitingPromptLanding = false
        lastPosition = nil
        lastDeadJumpAt = nil
        panel?.modeMeta = nil
        panel?.setScrollCursor(row: nil) { nil }
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
        case .step(let delta):
            sawG = false
            awaitingPromptLanding = false
            step(delta)
        case .scroll(let move):
            sawG = false
            // A page move carries the cursor with the viewport, so it keeps its place on screen.
            // The moves that name a destination put the cursor ON it instead, because landing the
            // thing you asked for somewhere in view and leaving the cursor elsewhere makes the
            // cursor a decoration.
            switch move {
            case .top:
                cursorRow = 0
                awaitingPromptLanding = false
            case .bottom:
                cursorRow = lastRow
                awaitingPromptLanding = false
            // Deferred, not set here. A prompt jump often moves nothing at all: `scrollPrompt`
            // finds no prompt in that direction and returns, and moving the cursor anyway makes
            // the band jump to the top of a screen that never scrolled. Wait to be told the
            // viewport actually moved.
            case .prompt(let delta):
                guard !reportDeadPromptJump(delta) else { return true }
                awaitingPromptLanding = true
            default: break
            }
            surface?.scroll(move)
            refreshCursor()
        }
        return true
    }

    /// Move the cursor one row, and scroll only once it has nowhere left to go.
    ///
    /// This is what makes it a cursor. Scrolling on every `j` would move the whole screen to
    /// track a marker that never moved, which is a scrollbar with extra steps.
    private func step(_ delta: Int) {
        let next = cursorRow + delta
        if next >= 0 && next <= lastRow {
            cursorRow = next
        } else {
            surface?.scroll(.lines(delta))  // pinned at an edge: the buffer moves under the cursor
        }
        refreshCursor()
    }

    /// The bottom row of the viewport. Zero while the surface has no metrics to report, which
    /// pins the cursor to the top row rather than letting it run off a grid of unknown size.
    private var lastRow: Int { max((surface?.cellMetrics?.rows ?? 1) - 1, 0) }

    private func refreshCursor() {
        guard isActive, let surface else { return }
        cursorRow = min(cursorRow, lastRow)
        panel?.setScrollCursor(row: cursorRow) { [weak surface] in surface?.cellMetrics }
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
        // Prompt jumps are vim's paragraph motion, and a prompt-delimited block of output is
        // exactly a paragraph. Same keys the diff viewer jumps changes with. Matched on the typed
        // character first, so a layout that doesn't put braces on shift-bracket still works.
        switch event.characters {
        case "{": return .scroll(.prompt(-1))
        case "}": return .scroll(.prompt(1))
        default: break
        }
        let shift = held.contains(.shift)
        switch (event.charactersIgnoringModifiers?.lowercased() ?? "", shift) {
        case ("j", false), (Self.downArrow, false): return .step(1)
        case ("k", false), (Self.upArrow, false): return .step(-1)
        case (" ", false): return .scroll(.pageFraction(1))
        case ("g", false): return afterG ? .scroll(.top) : .pendingTop
        case ("g", true): return .scroll(.bottom)
        case ("[", true): return .scroll(.prompt(-1))  // shift-bracket on a US layout
        case ("]", true): return .scroll(.prompt(1))
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
        lastPosition = position
        updateHeader(position: position)
        landPromptJump(position)
    }

    /// Place the cursor once a prompt jump has been confirmed to move the viewport.
    ///
    /// libghostty scrolls to a prompt by setting the viewport pin to it
    /// (`PageList.scrollPrompt`), and that pin IS the viewport's top row, so a jump that scrolls
    /// puts the prompt on row 0.
    ///
    /// Unless it landed at the bottom. A prompt already inside the live screen takes the
    /// `pinIsActive` branch, which sends the viewport to the bottom rather than pinning, and the
    /// prompt is then wherever it sits there. Prompt marks are OSC 133 state rather than text, so
    /// the chrome cannot find that row, and leaving the cursor alone beats moving it somewhere
    /// known to be wrong.
    /// Whether a prompt jump has nowhere to go, and say so if it doesn't. Returns true when the
    /// jump was refused, so the caller skips it.
    ///
    /// Both ends are read off the last reported position, which is exactly the condition
    /// libghostty checks: `scrollPrompt` searches from one row above the viewport and returns
    /// when there is no such row, so a viewport already at the top of the buffer can never find a
    /// prompt above it. The mirror at the bottom is the viewport already resting on the newest
    /// line. In between, whether a prompt exists in that direction is not knowable from the
    /// chrome (prompt marks are OSC 133 state rather than text), so those jumps go through and
    /// stay quiet.
    private func reportDeadPromptJump(_ delta: Int) -> Bool {
        guard let position = lastPosition else { return false }  // nothing known yet, let it try
        let word: String
        if delta < 0 {
            guard position.offset == 0 else { return false }
            word = "above"
        } else {
            guard position.linesBelow == 0 else { return false }
            word = "below"
        }
        // Throttled the way pane nav throttles its own: a held key would otherwise stack a toast
        // per repeat over the pane being read.
        let now = Date()
        if let last = lastDeadJumpAt, now.timeIntervalSince(last) < Self.deadJumpToastThrottle {
            return true
        }
        lastDeadJumpAt = now
        onRequestToast?(
            ToastContent(
                variant: .info,
                title: CommandCatalog.spec(for: .toggleScrollMode).title,
                message: "No prompt \(word) to jump to"))
        return true
    }

    private static let deadJumpToastThrottle: TimeInterval = 3

    private func landPromptJump(_ position: TerminalScrollPosition) {
        guard awaitingPromptLanding else { return }
        awaitingPromptLanding = false
        guard position.linesBelow > 0 else { return }
        cursorRow = 0
        refreshCursor()
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
