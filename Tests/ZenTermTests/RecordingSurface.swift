import AppKit
import TerminalKit

/// A seam-conforming fake for tests that need a `TerminalSurface` without a real
/// backend, recording the config it was started with and whether it was terminated.
final class RecordingSurface: NSObject, TerminalSurface {
    /// Reports its own resizes, the way `GhosttyHostView` does: the real backend pushes the new
    /// size from `setFrameSize` and the grid reflows inside that call, before it returns.
    final class ResizingView: NSView {
        var onResize: (() -> Void)?
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            onResize?()
        }
    }

    let resizingView = ResizingView()
    var view: NSView { resizingView }
    weak var delegate: TerminalSurfaceDelegate?
    var title = ""
    /// Driven by `focus()`, so a test can assert who the chrome actually handed focus to (matching
    /// the seam's own fake in `SeamTests`). Nothing un-focuses a surface through the protocol —
    /// the chrome focuses the one that should hold it — so there's no clear path to model.
    private(set) var isFocused = false
    var lastConfig: TerminalSurfaceConfig?
    /// Overrides the protocol extension's nil default so a test can drive cwd drift — the same
    /// property `PaneCanvasController.focusedCWD` prefers over its last OSC-reported value.
    var currentDirectory: URL?
    /// Overrides the protocol extension's false default so a test can mark a surface as having
    /// live work — what the ⌘W confirm reads through `hasBusyToolFloat`/`hasBusyDrawer`.
    var isBusy = false
    /// Overrides the protocol extension's nil default so a test can stand a surface up already
    /// repainted by OSC 11 — the state the chrome pulls from when it builds a host for a surface
    /// that was already running.
    var backgroundOverride: TerminalColor?
    var terminated = false
    /// When set, `start` reports a creation failure to the delegate instead of succeeding, which
    /// exercises the seam's dead-surface path without needing a real libghostty failure.
    var failOnStart = false
    private(set) var startCount = 0
    func start(_ config: TerminalSurfaceConfig) {
        startCount += 1
        lastConfig = config
        if let theme = config.theme, let behavior = config.behavior {
            lastAppearance = (theme, behavior)
        }
        if let fontSize = config.fontSize { fontSizes.append(fontSize) }
        // Mirror the real backend's async delivery (see `TerminalSurfaceDelegate`) so tests
        // exercise the same timing: the failure arrives after the caller has wired us up.
        if failOnStart {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.surfaceDidFailToStart(self)
            }
        }
    }
    /// The appearance this surface is currently wearing: what it was **started** with, then
    /// whatever `applyAppearance` last pushed. The protocol's default `applyAppearance` is a no-op,
    /// so without this a stub records nothing and the `.configDidChange` fan-out's reach into live
    /// surfaces is invisible to a test.
    ///
    /// Seeded from `start` deliberately. A real surface is already wearing its launch appearance,
    /// so a stub that starts blank would report a difference between a reload that re-pushed the
    /// same values and one that skipped the push — which is a difference the user cannot see.
    private(set) var lastAppearance: (theme: TerminalTheme, behavior: TerminalBehavior)?
    func applyAppearance(theme: TerminalTheme, behavior: TerminalBehavior) {
        lastAppearance = (theme, behavior)
    }
    /// Every font size pushed through the seam, in order. A list rather than a latest-value: the
    /// bug was a size reaching one surface and not its siblings, so a test has to be able to
    /// ask "did this surface get the push at all", which a nil-vs-value check on the focused pane
    /// alone cannot answer. Seeded by `start` for the same reason `lastAppearance` is — a real
    /// surface is already wearing the size it launched with.
    private(set) var fontSizes: [CGFloat] = []
    var lastFontSize: CGFloat? { fontSizes.last }
    func setFontSize(_ points: CGFloat) { fontSizes.append(points) }

    /// Counts `focus()` calls so a test can tell "was focused now" from the sticky `isFocused` (which,
    /// like the real protocol, is never cleared through the seam) — the discriminator for whether a
    /// send actually moved focus to its target.
    private(set) var focusCount = 0
    func focus() {
        isFocused = true
        focusCount += 1
    }
    func terminate() { terminated = true }
    /// Every `setFocused` push, in order. Distinct from `isFocused`, which `focus()` drives and
    /// nothing clears: this is how the surface was told to *render*, which is what a mode holding
    /// the keyboard over a still-focused pane changes.
    private(set) var focusRenders: [Bool] = []
    func setFocused(_ focused: Bool) { focusRenders.append(focused) }
    /// Records paste text so a test can assert a ⌘V was (or was not) routed into a surface — the
    /// discriminator for "did the modal card swallow paste, or did it fall through to the terminal".
    private(set) var pastes: [String] = []
    func paste(_ text: String) { pastes.append(text) }
    /// What a mouse drag has selected, which the find bar seeds itself from. Nil by default:
    /// most tests have no selection, and an accidental one would seed every search.
    var selectionText: String?
    func copySelection() -> String? { selectionText }
    /// Records scroll commands so a test can assert which key produced which move, and that a
    /// key outside scroll mode produced none.
    private(set) var scrolls: [TerminalScroll] = []
    func scroll(_ command: TerminalScroll) { scrolls.append(command) }

    /// Counts rather than flags, so a test can tell one press from two — the discriminator for a
    /// chord that fires twice off one keystroke.
    private(set) var clearScreenCount = 0
    private(set) var selectAllCount = 0
    private(set) var screenFileDispositions: [ScreenFileDisposition] = []
    var writeScreenFileCount: Int { screenFileDispositions.count }
    func clearScreen() { clearScreenCount += 1 }
    func selectAll() { selectAllCount += 1 }
    func writeScreenToFile(_ disposition: ScreenFileDisposition) {
        screenFileDispositions.append(disposition)
    }

    private(set) var searches: [String] = []
    private(set) var searchSteps: [TerminalSearchStep] = []
    private(set) var endSearchCount = 0
    func search(_ needle: String) { searches.append(needle) }
    func stepSearch(_ step: TerminalSearchStep) { searchSteps.append(step) }

    /// Whether `endSearch` reports END_SEARCH straight back, synchronously, the way libghostty
    /// does: it answers the binding action by calling the apprt from inside it. Off by default so
    /// the ordinary tests read plainly, and on for the one that covers the re-entrancy.
    var echoesEndSearch = false
    func endSearch() {
        endSearchCount += 1
        if echoesEndSearch { delegate?.surfaceDidEndSearch(self) }
    }

    /// The grid this surface claims to have. Defaults to a 24-row viewport rather than nil, so a
    /// test drives scroll mode's real cursor behavior: with no metrics the cursor is pinned to a
    /// one-row grid and every step scrolls, which passes while proving nothing.
    var cellMetrics: TerminalCellMetrics? = TerminalCellMetrics(
        columns: 80, rows: 24, cellWidth: 8, cellHeight: 16, gridInset: 2)

    /// Overrides the protocol extension's nil default so a test can stand a surface up with the
    /// backend's own selection already made, which is what scroll mode opens onto.
    var selectionOrigin: TerminalViewportCell?

    /// The screen this surface claims to show, one entry per viewport row. Defaults to two
    /// command blocks separated by a blank row, which is what paragraph motion moves between.
    var rows: [String] = {
        var rows = Array(repeating: "", count: 24)
        rows[2] = "❯ seq 1 3"
        rows[3] = "1"
        rows[4] = "2"
        rows[5] = "3"
        rows[6] = ""  // the blank between blocks
        rows[7] = "❯ echo hi"
        rows[8] = "hi"
        rows[9] = ""
        rows[10] = "~/bin"
        rows[11] = "❯"  // the prompt, and `cursorRow` above
        return rows
    }()

    /// Bounded by `cellMetrics` as well as by `rows`, the way the real backend is: `GhosttySurface`
    /// refuses a row at or past the grid height, so a fixture that answered one anyway would hide
    /// what a caller does with a row the grid has shrunk out from under.
    func text(viewportRow row: Int) -> String? {
        guard row < (cellMetrics?.rows ?? rows.count), rows.indices.contains(row) else { return nil }
        return rows[row]
    }

    /// Slices `rows`: first and last cut at their columns, everything between them whole.
    ///
    /// It does **not** model the backend's soft-wrap unwrapping. A fake that joined rows would make
    /// a test's expected string depend on where the fixture wrapped.
    /// Cells wide. Anything non-ASCII counts as two here, which is the case the column-to-cell
    /// mapping exists for; libghostty does the real widths.
    private static func width(_ character: Character) -> Int { character.isASCII ? 1 : 2 }

    /// Reads by **cell**, not by character index, and takes a character whose cells the span
    /// touches at either end. That is what ghostty's `selectionString wide char` test asserts, and
    /// it is the behavior the chrome's offset-to-cell search is built on.
    func text(in range: TerminalViewportRange) -> String? {
        guard rows.indices.contains(range.startRow), rows.indices.contains(range.endRow) else {
            return nil
        }
        let sliced = (range.startRow...range.endRow).map { row -> String in
            let from = row == range.startRow ? range.startColumn : 0
            let through = row == range.endRow ? range.endColumn : Int.max
            var cell = 0
            var taken = ""
            for character in rows[row] {
                let last = cell + Self.width(character) - 1
                if cell <= through && last >= from { taken.append(character) }
                cell = last + 1
            }
            return taken
        }
        return sliced.joined(separator: "\n")
    }
    /// Records a real Return keypress separately from pastes, so a test can assert submit went through
    /// the key path (a real Enter) rather than a bracketed `"\r"` paste that a TUI wouldn't act on.
    private(set) var submitCount = 0
    func submitLine() { submitCount += 1 }
}
