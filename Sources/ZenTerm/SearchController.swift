import AppKit
import AppLog
import TerminalKit

/// Scrollback search: the find bar, the match count, and the keys that step through matches.
///
/// The searching itself is libghostty's. It matches, counts, tracks which match is selected, and
/// paints every highlight through its own renderer. This type owns the bar, the needle, and the
/// two-phase keyboard handoff around them.
///
/// **Phase one** is typing. The bar holds first responder, so every key is the field's and the
/// needle goes down to the engine on a debounce. The bar shows a total, because the backend
/// selects no match until it is asked to.
///
/// **Phase two** starts at ⏎. First responder goes back to the pane, scroll mode comes up, and
/// `n`/`N` step through matches with the cursor following. The bar stays up and now reads which
/// match of how many.
///
/// Per window and pointed at one panel, like scroll mode, and it ends for all the same reasons.
@MainActor
final class SearchController {
    /// A phase-two keystroke. Phase one has no decoder: the field owns every key it gets.
    enum Key: Equatable {
        case step(TerminalSearchStep)
        case end
    }

    /// The four search events on their way up from a surface, carried as one value so the relay
    /// through the pane and tab controllers is one closure rather than four.
    enum Event: Equatable {
        case total(Int?)
        /// Zero-based, as the backend reports it.
        case selected(Int?)
        case ended
        /// The backend wants a bar, seeded with this needle when it has one.
        case wanted(needle: String)
    }

    /// Route one event to the right handler. Guarded on the reporting surface throughout, so a
    /// background pane cannot move the focused pane's bar.
    func handle(_ event: Event, from s: AnyObject & TerminalSurface, panel: @autoclosure () -> PanelHostView?) {
        switch event {
        case .total(let total): report(total: total, from: s)
        case .selected(let index): report(selected: index, from: s)
        case .ended: backendEnded(from: s)
        case .wanted(let needle):
            guard let panel = panel() else { return }
            begin(surface: s, panel: panel, seed: needle)
        }
    }

    private let scrollMode: ScrollModeController

    /// Whether the bar is up. True through both phases.
    private(set) var isActive = false

    /// Phase one: the field holds first responder and owns every keystroke. The window's mode
    /// handler reads this to stand down, or the interceptor would eat the typing before the field
    /// ever saw it.
    private(set) var isEditing = false

    private weak var surface: (AnyObject & TerminalSurface)?
    private weak var panel: PanelHostView?
    private weak var bar: FindBarView?

    private var needle = ""
    private var total: Int?
    private var selected: Int?
    private var debounce: DispatchWorkItem?

    /// Whether this needle has already been previewed. See `previewIfNothingVisible`.
    private var hasPreviewed = false

    /// Whether the commit is what brought scroll mode up. Search leaves behind only what it
    /// started: a reader already in scroll mode when the bar opened stays there on the way out.
    private var didStartScrollMode = false

    /// Fires when the bar goes up or comes down, so the window can install and remove its key hook
    /// without this type reaching into `KeyInterceptor`.
    var onActiveChanged: ((Bool) -> Void)?

    init(scrollMode: ScrollModeController) {
        self.scrollMode = scrollMode
    }

    // MARK: lifecycle

    /// Raise the bar over `panel` and take the keyboard, seeded with `seed` when the caller has a
    /// needle to offer. Already up: put the caret back in the field rather than mounting a second.
    func begin(surface: AnyObject & TerminalSurface, panel: PanelHostView, seed: String = "") {
        guard !isActive else {
            isEditing = true
            bar?.focusField()
            return
        }
        self.surface = surface
        self.panel = panel
        isActive = true
        isEditing = true

        let bar = panel.setFindBarShown(true)
        self.bar = bar
        bar?.onChange = { [weak self] in self?.needleDidChange($0) }
        bar?.onCommit = { [weak self] in self?.commit() }
        bar?.onCancel = { [weak self] in self?.end() }
        bar?.needle = seed
        showCount()

        // The bar displaces the terminal, so the grid loses a row or two and reflows. Lay out
        // before anything measures it, for the reason `ScrollModeController.begin` spells out at
        // the other end of the pane.
        settleLayout()

        bar?.focusField()
        Log.info("search opened", category: .panes)
        onActiveChanged?(true)

        needle = seed
        if !seed.isEmpty { surface.search(seed) }
    }

    /// Hand the keyboard back to the pane and settle on a match.
    ///
    /// Stepping is not a courtesy: libghostty matches eagerly but selects nothing on its own, so
    /// without it phase two would open on no match at all. It is skipped when a preview already
    /// picked one, or committing would walk straight past the match the reader is looking at.
    func commit() {
        guard isActive, isEditing else { return }
        isEditing = false
        surface?.focus()
        if let surface, let panel, !scrollMode.isActive {
            scrollMode.begin(surface: surface, panel: panel)
            didStartScrollMode = true
        }
        showCount()
        guard !needle.isEmpty else { return }
        if selected == nil { navigate(.next) } else { land(after: .next) }
    }

    /// Step to another match. The cursor follows once the backend reports which one it landed on.
    func navigate(_ step: TerminalSearchStep) {
        guard isActive, !needle.isEmpty else { return }
        pendingStep = step
        surface?.stepSearch(step)
    }

    /// Take the bar down and stop the engine. Idempotent, and called unconditionally from every
    /// retraction path, exactly as `ScrollModeController.end` is.
    func end() {
        guard isActive else { return }
        surface?.endSearch()
        teardown()
    }

    /// The backend ended the search itself, through a keybind it owns or its own teardown. Same
    /// teardown, minus the call back down: it is already gone.
    func backendEnded(from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        teardown()
    }

    private func teardown() {
        debounce?.cancel()
        debounce = nil
        isActive = false
        isEditing = false
        needle = ""
        total = nil
        selected = nil
        pendingStep = nil
        hasPreviewed = false
        // Search leaves behind only what it started. Committing brings scroll mode up on the
        // reader's behalf, so Esc has to take it back down again: one keystroke to find something,
        // one to be done with it. A reader who was already in scroll mode when the bar opened put
        // themselves there and keeps it.
        if didStartScrollMode {
            didStartScrollMode = false
            scrollMode.end()  // before the bar, so both constraint changes ride one layout pass
        }
        panel?.setFindBarShown(false)
        // The terminal takes its rows back, so the grid reflows again and scroll mode's cursor has
        // to be re-placed against it. Same order as raising the bar.
        settleLayout()
        bar = nil
        panel = nil
        surface = nil
        Log.info("search closed", category: .panes)
        onActiveChanged?(false)
    }

    /// Whether `s` is the surface this search is running on, so a pane that just exited ends only
    /// its own bar.
    func isDriving(_ s: AnyObject) -> Bool { surface === (s as AnyObject) }

    /// Land the layout the bar just changed, then let scroll mode re-measure against the grid it
    /// reflowed into. Measuring first reads the grid that is about to change out from under it.
    private func settleLayout() {
        panel?.layoutSubtreeIfNeeded()
        scrollMode.refreshGeometry()
    }

    // MARK: the needle

    /// Short needles wait, long ones go straight down.
    ///
    /// A one- or two-character needle matches most of a buffer, and the engine walks the whole of
    /// it for every keystroke. The delay is the same shape libghostty's own app uses.
    private func needleDidChange(_ text: String) {
        needle = text
        hasPreviewed = false
        debounce?.cancel()
        // A cleared needle stops the engine and must not wait: the highlights are still painted
        // until it does.
        guard !text.isEmpty, text.count < Self.debounceBelowLength else {
            selected = nil
            showCount()
            surface?.search(text)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            self.selected = nil
            self.surface?.search(text)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceDelay, execute: work)
    }

    #if DEBUG
        /// Type a needle without waiting out the debounce, so a test can drive the phases without
        /// an expectation around a timer.
        func beginNeedleForTesting(_ text: String) {
            needle = text
            bar?.needle = text
            surface?.search(text)
        }
    #endif

    // MARK: reports from the backend

    func report(total: Int?, from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        self.total = total
        showCount()
        previewIfNothingVisible()
    }

    /// Bring a match into view while the reader is still typing, but only when there is nothing to
    /// see without it.
    ///
    /// A needle whose only matches are in history counts up in the bar over a screen showing none
    /// of them, which asks the reader to press Return on faith. One step fixes that, and libghostty
    /// scrolls the match into view itself.
    ///
    /// It deliberately does **not** run when the viewport already holds a match. Stepping then would
    /// pull the screen off the answer that was already in front of them, which is the part of vim's
    /// `incsearch` worth leaving out.
    private func previewIfNothingVisible() {
        // Once per needle. `SEARCH_TOTAL` fires repeatedly as the engine works back through the
        // buffer, and a step on each report would drag the viewport through a match per report.
        guard isEditing, !hasPreviewed, (total ?? 0) > 0, !needle.isEmpty else { return }
        guard !viewportHoldsNeedle() else { return }
        hasPreviewed = true
        navigate(.next)
    }

    private func viewportHoldsNeedle() -> Bool {
        guard let surface else { return false }
        let rows = 0..<(surface.cellMetrics?.rows ?? 0)
        return rows.contains {
            !Self.occurrenceColumns(of: needle, in: surface.text(viewportRow: $0) ?? "").isEmpty
        }
    }

    func report(selected: Int?, from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        self.selected = selected
        showCount()
        guard let step = pendingStep, selected != nil else { return }
        pendingStep = nil
        land(after: step)
    }

    private func showCount() {
        // Phase one shows the total alone. The backend has selected nothing yet, so an index would
        // be an invention.
        bar?.showCount(total: total, selected: isEditing ? nil : selected)
    }

    /// The step we are waiting on a selection for, so a selection the backend reports on its own
    /// (a needle change resetting it) does not move the cursor.
    private var pendingStep: TerminalSearchStep?

    // MARK: landing the cursor

    /// Put scroll mode's cursor on the match the backend just selected.
    ///
    /// **The backend never says where a match is.** It reports an index; the geometry goes to its
    /// renderer and never crosses the C API. So the cell is found by reading the viewport back and
    /// looking for the needle, which is inference rather than a lookup and can pick the wrong
    /// occurrence when one screen holds several.
    ///
    /// That is a fair trade here only because the failure is visible: libghostty paints the match
    /// it selected at the same time, so a disagreement is two markers on one screen and one `j`
    /// fixes it. A silently wrong cursor would not be worth the keystrokes it saves.
    private func land(after step: TerminalSearchStep) {
        guard scrollMode.isActive, let surface else { return }
        let rows = (0..<(surface.cellMetrics?.rows ?? 0)).map { surface.text(viewportRow: $0) ?? "" }
        guard
            let cell = Self.matchCell(
                needle: needle, rows: rows, from: scrollMode.cursor, step: step)
        else { return }
        scrollMode.land(on: cell)
    }

    /// Where the selected match is, read off the viewport.
    ///
    /// Direction is the whole of it. libghostty walks matches newest to oldest, so `next` moves
    /// **up** the screen and `previous` down, and the nearest occurrence that way is the one it
    /// just selected. Nothing that way on screen means it had to scroll to reach the match, and a
    /// scroll parks the match's own row at the top of the viewport, so the topmost occurrence is
    /// the answer. One rule covers both, with no viewport bookkeeping to drift.
    ///
    /// Case folding is ASCII-only, matching the engine's `std.ascii.indexOfIgnoreCase`. A match
    /// that soft-wraps across two rows is not found, and the cursor stays where it is.
    static func matchCell(
        needle: String, rows: [String], from cursor: ScrollCell, step: TerminalSearchStep
    ) -> ScrollCell? {
        guard !needle.isEmpty else { return nil }
        let occurrences = rows.enumerated().flatMap { row, text in
            occurrenceColumns(of: needle, in: text).map { ScrollCell(row: row, column: $0) }
        }
        guard !occurrences.isEmpty else { return nil }
        let ahead = occurrences.filter {
            let isBefore = $0.row < cursor.row || ($0.row == cursor.row && $0.column < cursor.column)
            return step == .next ? isBefore : !isBefore && $0 != cursor
        }
        let nearest = ahead.min {
            distance($0, from: cursor) < distance($1, from: cursor)
        }
        return nearest ?? occurrences.first
    }

    /// Rows first, then columns: a match two rows away is further than one at the other end of
    /// this row, however many characters lie between them.
    private static func distance(_ cell: ScrollCell, from cursor: ScrollCell) -> (Int, Int) {
        (abs(cell.row - cursor.row), abs(cell.column - cursor.column))
    }

    /// Every column `needle` starts at in `text`, folding case the way the engine does.
    ///
    /// A column here is a character offset into the row, which is what the rest of scroll mode
    /// means by one too. See `ScrollCell` for where that parts company with a cell on a wide
    /// character.
    private static func occurrenceColumns(of needle: String, in text: String) -> [Int] {
        let haystack = Array(text.lowercased())
        let pattern = Array(needle.lowercased())
        guard !pattern.isEmpty, haystack.count >= pattern.count else { return [] }
        return (0...(haystack.count - pattern.count)).filter { start in
            Array(haystack[start..<(start + pattern.count)]) == pattern
        }
    }

    // MARK: keys

    /// Handle one phase-two `keyDown`. Returns whether it was consumed.
    func handle(_ event: NSEvent) -> Bool {
        guard isActive, !isEditing, let key = Self.key(for: event) else { return false }
        switch key {
        case .step(let step): navigate(step)
        case .end: end()
        }
        return true
    }

    /// Decode a phase-two keystroke, or nil for anything this mode does not claim.
    ///
    /// Pure and static, the same seam `ScrollModeController.command(for:afterG:)` uses, and
    /// shiftedness comes from the modifier flags for the same reason: Caps Lock uppercases too, so
    /// reading the character's case would turn every `n` into an `N`.
    ///
    /// A ⌘ or ⌥ chord is declined, and that is the line that matters. `KeyInterceptor` is a local
    /// monitor running ahead of menu key equivalents, so claiming one here would kill ⌘N, ⌘W and
    /// ⌘Q for as long as the bar is up.
    static func key(for event: NSEvent) -> Key? {
        let held = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard held.isSubset(of: .shift) else { return nil }
        if event.keyCode == Self.escapeKeyCode { return .end }
        let backwards = held.contains(.shift)
        if event.keyCode == Self.returnKeyCode || event.keyCode == Self.keypadEnterKeyCode {
            return .step(backwards ? .previous : .next)
        }
        guard event.charactersIgnoringModifiers?.lowercased() == "n" else { return nil }
        return .step(backwards ? .previous : .next)
    }

    /// Needles shorter than this wait out `debounceDelay` before they reach the engine.
    private static let debounceBelowLength = 3
    private static let debounceDelay: TimeInterval = 0.3
    private static let escapeKeyCode: UInt16 = 53
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
}
