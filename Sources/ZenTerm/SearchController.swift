import AppKit
import AppLog
import TerminalKit

/// Find: the bar, the match count, and the keys that step through matches. The
/// searching itself is libghostty's; this owns the bar, the needle, and the two-phase keyboard
/// handoff around them.
///
/// **Phase one** is typing: the bar holds first responder and the needle goes down on a debounce.
/// **Phase two** starts at ⏎: first responder returns to the pane, scroll mode comes up, and
/// `n`/`N` step through matches with the cursor following.
///
/// Per window and pointed at one panel, like scroll mode, and it ends for the same reasons.
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
    func handle(_ event: Event, from s: AnyObject & TerminalSurface, panel: @autoclosure () -> TerminalModeHost?) {
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
    private weak var panel: TerminalModeHost?
    private weak var bar: FindBarView?

    private var needle = ""
    private var total: Int?
    private var selected: Int?
    private var debounce: DispatchWorkItem?

    /// A needle the engine has not been told about yet, or nil once it has. Holding the needle
    /// itself cannot desync from whether it was sent, which a pending work item could: either state
    /// of one made a commit re-send a needle libghostty already had and step the reader one match
    /// past the one they were watching.
    private var unsent: String?

    /// Whether this needle has already been previewed. See `previewIfNothingVisible`.
    private var hasPreviewed = false

    /// Whether a step has been asked for on this needle, answered or not. `selected` cannot stand
    /// in: it mirrors the backend and lags, so a Return arriving before the report gets back would
    /// step a second time and land one match past the one they were looking at.
    private var didRequestSelection = false

    /// Whether the commit is what brought scroll mode up. Search leaves behind only what it
    /// started: a reader already in scroll mode when the bar opened stays there on the way out.
    private var didStartScrollMode = false

    /// Whether a step has carried the viewport off where it was. Stepping is the only thing here
    /// that moves it, and it is what has to be undone rather than left stranded.
    private var didMoveViewport = false

    /// Fires when the bar goes up or comes down, and again on a commit, so the window can install
    /// its key hook without this type reaching into `KeyInterceptor`. Read it as "reconcile the
    /// mode state now": the commit is a phase change that takes first responder back, and the
    /// unfocused render has to be re-asserted over what the responder chain just did.
    var onActiveChanged: ((Bool) -> Void)?

    init(scrollMode: ScrollModeController) {
        self.scrollMode = scrollMode
    }

    // MARK: lifecycle

    /// A selection as a needle: its first line, trimmed.
    ///
    /// **A needle is one line because everything downstream of it is.** The engine would match
    /// across a line break, but the scan, the cursor and the landing are per-row, so a multi-line
    /// needle counted and highlighted matches nothing could navigate to. The field then shows
    /// exactly what will be searched. Trailing blanks go too, since a selection reaching a row's
    /// end drags in cells the program never painted.
    private static func cleaned(_ seed: String) -> String {
        seed.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Raise the bar over `panel` and take the keyboard, seeded with `seed` when the caller has a
    /// needle to offer. Already up: put the caret back in the field rather than mounting a second.
    func begin(surface: AnyObject & TerminalSurface, panel: TerminalModeHost, seed rawSeed: String = "") {
        let seed = Self.cleaned(rawSeed)
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

        // Raised with the bar so the pane reflows once for the whole search: a second reflow at
        // commit snaps the viewport toward the bottom and throws away the match being read.
        //
        // It reads FIND rather than SCROLL because the bar owns the keyboard through phase one and
        // none of scroll mode's keys are live yet. Skipped when scroll mode is already up, where
        // the header is its own and says so correctly.
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
        guard let text = unsent else { return }
        debounce?.cancel()
        debounce = nil
        unsent = nil
        selected = nil
        didRequestSelection = false  // the needle is only now reaching the engine
        surface?.search(text)
    }

    /// Step to another match. The cursor follows once the backend reports which one it landed on.
    func navigate(_ step: TerminalSearchStep) {
        guard isActive, !needle.isEmpty else { return }
        pendingStep = step
        didMoveViewport = true
        didRequestSelection = true
        rowsAtStep = surface.map(Self.viewportRows(of:))
        surface?.stepSearch(step)
    }

    /// Put the viewport back where the reader had it before the search moved it, which is usually
    /// but not always the bottom: someone who had scrolled into a build log first gets that place
    /// back rather than the live end.
    ///
    /// Only when a step took the viewport away, and only when the reader is not being left in a
    /// scroll mode of their own, where the match is what they asked to see.
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
        rowsAtStep = nil
        hasPreviewed = false
        didRequestSelection = false
        unsent = nil
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
        // The layout usually reports a reflow on its own, so this is the second call for one
        // change. Kept anyway: a bar that costs the pane no whole row reshapes nothing, reports
        // nothing, and the overlay still has to be re-placed against the grid it now sits in.
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
        debounce?.cancel()
        debounce = nil
        // A cleared needle stops the engine and must not wait: the highlights are still painted
        // until it does.
        guard !text.isEmpty, text.count < Self.debounceBelowLength else {
            unsent = nil
            selected = nil
            showCount()
            surface?.search(text)
            return
        }
        unsent = text
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            self.unsent = nil
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
    /// see without it: a needle whose matches are all in history counts up over a screen showing
    /// none of them, which asks for a Return on faith.
    ///
    /// Deliberately does **not** run when the viewport already holds a match, since stepping would
    /// pull the screen off the answer already in front of them.
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
    /// **The backend never says where a match is**: it reports an index and the geometry never
    /// crosses the C API. So the cell is inferred by reading the viewport back, which can pick the
    /// wrong occurrence when one screen holds several. A fair trade only because libghostty paints
    /// the match it selected, so a disagreement is two visible markers and one `j` fixes it.
    private func land(after step: TerminalSearchStep) {
        guard scrollMode.isActive, let surface else { return }
        let rows = Self.viewportRows(of: surface)
        guard
            let cell = Self.matchCell(
                needle: needle, rows: rows, from: scrollMode.cursor, step: step,
                viewportMoved: rowsAtStep.map { $0 != rows } ?? false, selected: selected,
                total: total)
        else { return }
        scrollMode.land(on: cell)
    }

    private static func viewportRows(of surface: TerminalSurface) -> [String] {
        (0..<(surface.cellMetrics?.rows ?? 0)).map { surface.text(viewportRow: $0) ?? "" }
    }

    /// The whole viewport as the outstanding step went out, so its answer can be compared against
    /// the screen it produced. Nil before the first step.
    ///
    /// **Whether the step moved the viewport cannot be read off the scroll offset.** libghostty
    /// emits a scrollbar report from the renderer thread and only while drawing a frame
    /// (`renderer/generic.zig`: "The scrollbar is only emitted during draws"), while the selected
    /// index is pushed straight from the search thread the moment the match is picked. So the
    /// offset in hand when the selection lands is a frame or more behind, and comparing it against
    /// the offset at step time read "did not move" for a step that plainly did, whenever no frame
    /// happened to land in between.
    ///
    /// The screen itself answers synchronously instead: the search thread scrolls under the
    /// terminal mutex before it reports the selection (`terminal/search/Thread.zig`), so the rows
    /// read back at landing time are already the ones on screen.
    ///
    /// **The whole viewport rather than the cursor's line**, because a screen of repeated prompts
    /// or repeated log output can scroll onto text identical to the line the cursor left, and one
    /// line compared against one line calls that standing still. A scroll has to change some row
    /// unless every row on screen reads the same. It also asks nothing of the cursor, which is what
    /// makes it right on the preview step, where scroll mode is not up yet and `scrollMode.cursor`
    /// is a leftover from whenever it last was.
    private var rowsAtStep: [String]?

    /// Where the selected match is, read off the viewport.
    ///
    /// Direction carries the case where the viewport stood still: libghostty walks matches newest
    /// to oldest, so `next` moves **up** the screen and the nearest occurrence that way is the one
    /// it just selected.
    ///
    /// Case folding is ASCII-only, matching the engine. A match that soft-wraps across two rows is
    /// not found and the cursor stays put.
    static func matchCell(
        needle: String, rows: [String], from cursor: ScrollCell, step: TerminalSearchStep,
        viewportMoved: Bool, selected: Int?, total: Int?
    ) -> ScrollCell? {
        guard !needle.isEmpty else { return nil }
        let occurrences = rows.enumerated().flatMap { row, text in
            occurrenceColumns(of: needle, in: text).map { ScrollCell(row: row, column: $0) }
        }
        guard !occurrences.isEmpty else { return nil }
        // A step that moved the viewport parks the match's own row at the top of it: the search
        // thread scrolls to the match's start pin, and only when the match is not already on
        // screen. The cursor is a coordinate in the viewport that just went away, so a direction
        // scan from it is worse than no scan at all.
        if viewportMoved {
            let onTopRow = occurrences.filter { $0.row == 0 }
            // `next` walks newest to oldest, so within the parked row the match it stopped on is
            // the last one when stepping backwards through the buffer and the first going forwards.
            if !onTopRow.isEmpty { return step == .next ? onTopRow.last : onTopRow.first }
            if let clamped = clampedMatch(
                in: occurrences, step: step, selected: selected, total: total)
            {
                return clamped
            }
            return step == .next ? occurrences.first : occurrences.last
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
        // Nothing that way is the same end-of-buffer clamp as above, reached without a scroll. The
        // fallback follows the direction for the same reason: throwing the cursor to the top of the
        // screen on a step that went down is the mirror of the bug fixed above it.
        return (step == .next ? before.last ?? occurrences.first : after.first ?? occurrences.last)
    }

    /// The selected match when the scroll ran out of buffer and could not park it at the top.
    ///
    /// Counting, not guessing. A clamped viewport reaches a buffer end, so every match between the
    /// selected one and that end is on screen, and the backend's index says how many those are.
    /// Stepping toward newer matches clamps at the live end, where the `selected` matches newer
    /// than this one all sit below it: it is `selected` occurrences up from the bottom. Stepping
    /// toward older ones clamps at the top, where the `total - 1 - selected` older matches all sit
    /// above it, putting it that far down from the first.
    ///
    /// Direction alone cannot do this, which is what both reviewers said and where the first fix
    /// stopped: it took the bottom-most occurrence, right only when the clamped screen held one
    /// candidate. Nil when the count does not land inside the screen, which means something in the
    /// premise is off (a soft-wrapped match the scan missed, most likely) and a guess is not owed.
    private static func clampedMatch(
        in occurrences: [ScrollCell], step: TerminalSearchStep, selected: Int?, total: Int?
    ) -> ScrollCell? {
        guard let selected else { return nil }
        let index: Int
        switch step {
        case .previous: index = occurrences.count - 1 - selected
        case .next:
            guard let total else { return nil }
            index = total - 1 - selected
        }
        guard occurrences.indices.contains(index) else { return nil }
        return occurrences[index]
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

    /// Decode a phase-two keystroke, or nil for anything this mode does not claim. Pure and static,
    /// the same seam `ScrollKeymap.key(for:pending:hasSelection:)` uses, and shiftedness comes from
    /// the modifier flags for the same Caps Lock reason. Declining a ⌘ or ⌥ chord is the line that
    /// matters: this runs ahead of menu key equivalents, so claiming one would kill ⌘N, ⌘W and ⌘Q.
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
