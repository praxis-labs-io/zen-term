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

    /// Whether a step has been asked for on this needle, answered or not.
    ///
    /// `selected` cannot stand in for this. It is a mirror of the backend's state and it lags: a
    /// preview steps, libghostty paints the match, and the reader presses Return before the report
    /// gets back. Branching on the mirror there steps a second time and lands them one match past
    /// the one they were looking at.
    private var didRequestSelection = false

    /// Whether the commit is what brought scroll mode up. Search leaves behind only what it
    /// started: a reader already in scroll mode when the bar opened stays there on the way out.
    private var didStartScrollMode = false

    /// Whether a step has carried the viewport off where it was. Stepping is the only thing here
    /// that moves it, and it is what has to be undone rather than left stranded.
    private var didMoveViewport = false

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
            // A seed arriving over an open bar replaces what is in it. Searching the selection with
            // the bar already up otherwise puts the caret back in a stale needle and looks broken.
            if !seed.isEmpty {
                bar?.needle = seed
                needleDidChange(seed)
            }
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

        // The header goes up with the bar, and this is the reason the pane reflows once for the
        // whole search rather than twice. Scroll mode raises the same header when a commit brings
        // it up, and a second reflow there snaps the viewport toward the bottom, which throws away
        // the match the reader was looking at. Raised here, the commit changes no geometry at all.
        //
        // It reads FIND rather than SCROLL because that is what is true: the bar owns the keyboard
        // through phase one and none of scroll mode's keys are live yet. Saying SCROLL over a mode
        // that takes no keys is the state the ⌘⇧S path was fixed to avoid.
        if !scrollMode.isActive { panel.modeMeta = PanelMeta(title: "Find", action: .toggleSearch) }

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
        // Taking first responder back drives the surface's focus through the responder chain, and
        // a mode still holds the keyboard, so the unfocused render has to be re-asserted over it.
        // Starting scroll mode above happens to do that through its own callback, which is why
        // this was invisible until a search opened over a scroll mode that was already up.
        onActiveChanged?(isActive)
        showCount()
        guard !needle.isEmpty else { return }
        // A short needle is still sitting in the debounce, and the engine has not been told about
        // it. Stepping now navigates a search that does not exist yet, the backend answers false,
        // and by the time the timer fires nothing is left to move the cursor. Send it first.
        flushPendingNeedle()
        guard didRequestSelection else {
            navigate(.next)
            return
        }
        // A step is already out. If its answer has landed, put the cursor on it now; if it has not,
        // `report(selected:)` still holds the pending step and will do it when it arrives.
        if selected != nil { land(after: .next) }
    }

    /// Deliver a debounced needle now rather than on its timer.
    private func flushPendingNeedle() {
        guard debounce != nil else { return }
        debounce?.cancel()
        debounce = nil
        selected = nil
        didRequestSelection = false  // the needle is only now reaching the engine
        surface?.search(needle)
    }

    /// Step to another match. The cursor follows once the backend reports which one it landed on.
    func navigate(_ step: TerminalSearchStep) {
        guard isActive, !needle.isEmpty else { return }
        pendingStep = step
        didMoveViewport = true
        didRequestSelection = true
        offsetAtStep = lastPosition?.offset
        surface?.stepSearch(step)
    }

    /// Put the viewport back where the reader had it before the search moved it.
    ///
    /// Back to the bottom is what this usually means, because a search usually starts at a live
    /// prompt. It is not the same rule, though: a reader who had already scrolled into a build log
    /// before opening the bar gets that place back rather than being dumped at the live end.
    ///
    /// Only when a step took the viewport away, and only when the reader is not being left in a
    /// scroll mode of their own: they are still reading, and the match is what they asked to be
    /// shown.
    private func restoreViewport() {
        guard didMoveViewport else { return }
        let readerOwnsScrollMode = scrollMode.isActive && !didStartScrollMode
        // Cleared either way. Left set on this branch it survives into the next search, which then
        // scrolls on the way out having never moved anything.
        didMoveViewport = false
        guard !readerOwnsScrollMode else { return }
        guard let entryOffset, let position = lastPosition else {
            surface?.scroll(.bottom)  // no report to measure against; the live end is the best guess
            return
        }
        let delta = entryOffset - position.offset
        if delta == 0 { return }
        surface?.scroll(.lines(delta))
    }

    /// Where the viewport sat when the bar went up, and where it sits now. Both come from the
    /// backend's own scroll reports, which fire on output as well as on a scroll.
    private var entryOffset: Int?
    private var lastPosition: TerminalScrollPosition?

    func report(position: TerminalScrollPosition, from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        lastPosition = position
        if entryOffset == nil { entryOffset = position.offset }
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
        // libghostty answers `end_search` by calling END_SEARCH straight back, synchronously, from
        // inside the binding action. So `end()` re-enters here through `backendEnded` and finishes
        // the whole teardown before its own call to this runs. Without the guard the second pass
        // re-fires `onActiveChanged` and scrolls the viewport a second time.
        guard isActive else { return }
        debounce?.cancel()
        debounce = nil
        isActive = false
        // The bar took first responder on the way in and has to give it back, or the pane draws a
        // live cursor while every keystroke goes to a hidden field. Only when the field still holds
        // it: a teardown caused by a modal card opening must not steal focus back from the card.
        if bar?.isFieldFirstResponder == true { surface?.focus() }
        isEditing = false
        needle = ""
        total = nil
        selected = nil
        pendingStep = nil
        hasPreviewed = false
        didRequestSelection = false
        // Before the surface goes, and before scroll mode does: `restoreViewport` reads whether the
        // reader owns the mode to decide, and ending it first would make every case look owned.
        restoreViewport()
        // Search leaves behind only what it started. Committing brings scroll mode up on the
        // reader's behalf, so Esc has to take it back down again: one keystroke to find something,
        // one to be done with it. A reader who was already in scroll mode when the bar opened put
        // themselves there and keeps it.
        if didStartScrollMode {
            didStartScrollMode = false
            scrollMode.end()  // before the bar, so both constraint changes ride one layout pass
        }
        // Only ours to take down. A scroll mode the reader opened themselves is still up and owns
        // the header, and clearing it here would strip the indicator off a live mode.
        if !scrollMode.isActive { panel?.modeMeta = nil }
        panel?.setFindBarShown(false)
        // The terminal takes its rows back, so the grid reflows again and scroll mode's cursor has
        // to be re-placed against it. Same order as raising the bar.
        settleLayout()
        bar = nil
        panel = nil
        surface = nil
        entryOffset = nil
        lastPosition = nil
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
        // A new needle drops the backend's selection, so any step asked for on the old one is moot.
        didRequestSelection = false
        // Nilled, not just cancelled. `flushPendingNeedle` reads this to mean "a needle is still
        // waiting on its timer", and a cancelled item left in place says that falsely for the rest
        // of the search: committing then re-sends a needle the engine already has, which it ignores
        // as unchanged, and clears the selection state that told the commit not to step again.
        debounce?.cancel()
        debounce = nil
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

        /// Type a needle down the real path, debounce included, for the cases where the debounce
        /// is the thing under test.
        func typeForTesting(_ text: String) {
            bar?.needle = text
            needleDidChange(text)
        }
    #endif

    // MARK: reports from the backend

    func report(total: Int?, from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        self.total = total
        showCount()
        // A needle typed one character past its last match leaves the viewport parked on something
        // that no longer matches anything. Nothing to show means going back to where the reader
        // was, not hanging on the previous needle's answer.
        guard (total ?? 0) > 0 else {
            hasPreviewed = false
            restoreViewport()
            return
        }
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
        // Latched before the viewport check, not after. `SEARCH_TOTAL` fires repeatedly as the
        // engine works back through the buffer, and latching only on the branch that steps means a
        // needle already on screen re-reads every viewport row on every report: one `read_text` per
        // row, each taking the renderer mutex, on the main thread.
        hasPreviewed = true
        guard !viewportHoldsNeedle() else { return }
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
        // Whether the step had to scroll to reach the match. The cursor names a row in the viewport
        // it was standing in, so once that viewport moves the coordinate is meaningless and a
        // direction scan from it walks to whichever match happens to sit near the stale row. The
        // error compounds over a run of steps, and a row holding several matches gives it more
        // wrong answers to choose from.
        let scrolled = lastPosition?.offset != offsetAtStep
        guard
            let cell = Self.matchCell(
                needle: needle, rows: rows, from: scrollMode.cursor, step: step, scrolled: scrolled)
        else { return }
        scrollMode.land(on: cell)
    }

    /// Where the viewport sat when the outstanding step was sent, so the answer can tell whether it
    /// moved. Nil before any report has arrived, which reads as "no movement to detect".
    private var offsetAtStep: Int?

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
        needle: String, rows: [String], from cursor: ScrollCell, step: TerminalSearchStep,
        scrolled: Bool
    ) -> ScrollCell? {
        guard !needle.isEmpty else { return nil }
        let occurrences = rows.enumerated().flatMap { row, text in
            occurrenceColumns(of: needle, in: text).map { ScrollCell(row: row, column: $0) }
        }
        guard !occurrences.isEmpty else { return nil }
        // A step that scrolled parks the match's own row at the top of the viewport, which is the
        // one case the backend tells us exactly. The cursor is a coordinate in the viewport that
        // just went away, so a direction scan from it is worse than no scan at all.
        if scrolled {
            let onTopRow = occurrences.filter { $0.row == 0 }
            // `next` walks newest to oldest, so within the parked row the match it stopped on is
            // the last one when stepping backwards through the buffer and the first going forwards.
            return step == .next ? onTopRow.last ?? occurrences.first : onTopRow.first ?? occurrences.first
        }
        // `occurrences` is already in buffer order, rows down and columns across, and the engine
        // steps in exactly that order. So the answer is the immediate neighbour: the last match
        // before the cursor going back, the first after it going forward. Nearest-by-distance was
        // wrong the moment a row held two matches, because it would take the closer column on the
        // row above rather than the one the engine actually stopped on.
        let before = occurrences.filter {
            $0.row < cursor.row || ($0.row == cursor.row && $0.column < cursor.column)
        }
        let after = occurrences.filter {
            $0.row > cursor.row || ($0.row == cursor.row && $0.column > cursor.column)
        }
        return (step == .next ? before.last : after.first) ?? occurrences.first
    }

    /// Every column `needle` starts at in `text`, folding case the way the engine does.
    ///
    /// A column here is a character offset into the row, which is what the rest of scroll mode
    /// means by one too. See `ScrollCell` for where that parts company with a cell on a wide
    /// character.
    private static func occurrenceColumns(of needle: String, in text: String) -> [Int] {
        let haystack = text.map(asciiFolded)
        let pattern = needle.map(asciiFolded)
        guard !pattern.isEmpty, haystack.count >= pattern.count else { return [] }
        return (0...(haystack.count - pattern.count)).filter { start in
            Array(haystack[start..<(start + pattern.count)]) == pattern
        }
    }

    /// Lowercase A through Z and nothing else, which is what `std.ascii.indexOfIgnoreCase` does.
    ///
    /// `lowercased()` is the wrong tool twice over. It folds the whole of Unicode, so `ÉCOLE` would
    /// match a needle the engine never matched and the cursor would land on text carrying no
    /// highlight. And it can change a string's character count, which would make every column after
    /// it an offset into the folded string rather than into the row the cursor is placed on.
    private static func asciiFolded(_ character: Character) -> Character {
        guard let ascii = character.asciiValue, ascii >= UInt8(ascii: "A"), ascii <= UInt8(ascii: "Z")
        else { return character }
        return Character(UnicodeScalar(ascii + 32))
    }

    // MARK: keys

    /// Handle one phase-two `keyDown`. Returns whether it was consumed.
    func handle(_ event: NSEvent) -> Bool {
        guard isActive, !isEditing, let key = Self.key(for: event) else { return false }
        switch key {
        case .step(let step): navigate(step)
        case .end:
            // A visual selection owns Esc first. Scroll mode's `.cancel` hands the selection back
            // without leaving the mode, and claiming Esc here would take the selection, the mode
            // and the bar in one keystroke, with nothing left to undo a mis-anchored `v`.
            guard scrollMode.selection == nil else { return false }
            end()
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
