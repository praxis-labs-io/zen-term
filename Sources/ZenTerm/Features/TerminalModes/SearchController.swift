import AppKit
import AppLog
import TerminalKit

@MainActor
final class SearchController {
    enum Key: Equatable {
        case step(TerminalSearchStep)
        case end
    }

    enum Event: Equatable {
        case total(Int?)
        case selected(Int?, start: TerminalGridPoint?)
        case ended
        case wanted(needle: String)
    }

    func handle(_ event: Event, from s: AnyObject & TerminalSurface, panel: @autoclosure () -> TerminalModeHost?) {
        switch event {
        case .total(let total): report(total: total, from: s)
        case .selected(let index, let start): report(selected: index, start: start, from: s)
        case .ended: backendEnded(from: s)
        case .wanted(let needle):
            guard let panel = panel() else { return }
            begin(surface: s, panel: panel, seed: needle)
        }
    }

    private let scrollMode: ScrollModeController

    private(set) var isActive = false

    private(set) var isEditing = false

    private weak var surface: (AnyObject & TerminalSurface)?
    private weak var panel: TerminalModeHost?
    private weak var bar: FindField?

    private var needle = ""
    private var total: Int?
    private var selected: Int?
    private var debounce: DispatchWorkItem?

    /// The needle itself rather than a work item, so a step cannot re-send one libghostty already has.
    private var unsent: String?

    /// `selected` lags the backend, so a Return before its report would otherwise step twice.
    private var didRequestSelection = false
    private var didWeighSelection = false

    private var didStartScrollMode = false

    private var didMoveViewport = false

    var onActiveChanged: ((Bool) -> Void)?

    init(scrollMode: ScrollModeController) {
        self.scrollMode = scrollMode
    }

    /// One line, because the scan, the cursor and the landing are all per-row.
    private static func cleaned(_ seed: String) -> String {
        seed.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    func begin(surface: AnyObject & TerminalSurface, panel: TerminalModeHost, seed rawSeed: String = "") {
        let seed = Self.cleaned(rawSeed)
        guard !isActive else {
            if bar?.isFieldFirstResponder != true { bar?.focusField() }
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

        let bar = panel.setFindFieldShown(true)
        self.bar = bar
        bar?.onChange = { [weak self] in self?.needleDidChange($0) }
        bar?.onStep = { [weak self] in self?.step($0) }
        bar?.onCancel = { [weak self] in self?.end() }
        bar?.onFocusChange = { [weak self] in self?.editingDidChange($0) }
        bar?.needle = seed
        showCount()

        bar?.focusField()
        Log.info("search opened", category: .panes)
        onActiveChanged?(true)

        needle = seed
        if !seed.isEmpty { surface.search(seed) }
    }

    private func editingDidChange(_ editing: Bool) {
        guard isActive, editing != isEditing else { return }
        isEditing = editing
        onActiveChanged?(isActive)
    }

    /// libghostty selects nothing until asked, so the first step lands on the newest match whichever way it points.
    func step(_ step: TerminalSearchStep) {
        guard isActive, !needle.isEmpty else { return }
        flushPendingNeedle()
        navigate(didRequestSelection ? step : .next)
    }

    /// Steps unless a match is already picked: libghostty matches eagerly but selects nothing.
    func enterScrollMode() {
        guard isActive, isEditing else { return }
        isEditing = false
        surface?.focus()
        if let surface, let panel, !scrollMode.isActive {
            scrollMode.begin(surface: surface, panel: panel)
            didStartScrollMode = true
        }
        onActiveChanged?(isActive)
        showCount()
        guard !needle.isEmpty else { return }
        flushPendingNeedle()
        guard didRequestSelection else {
            navigate(.next)
            return
        }
        guard selected != nil, case .at(let landing) = fieldLanding?.place else { return }
        scrollMode.land(on: landing)
    }

    private func flushPendingNeedle() {
        guard let text = unsent else { return }
        debounce?.cancel()
        debounce = nil
        unsent = nil
        selected = nil
        fieldLanding = nil
        didRequestSelection = false
        didWeighSelection = false
        surface?.search(text)
    }

    func navigate(_ step: TerminalSearchStep) {
        guard isActive, !needle.isEmpty else { return }
        pendingStep = step
        didRequestSelection = true
        viewportTopAtStep = surface?.grid?.viewportTop
        surface?.stepSearch(step)
    }

    private func restoreViewport() {
        guard didMoveViewport else { return }
        let readerOwnsScrollMode = scrollMode.isActive && !didStartScrollMode
        didMoveViewport = false
        guard !readerOwnsScrollMode else { return }
        guard let entryOffset, let position = lastPosition else {
            surface?.scroll(.bottom)
            return
        }
        let delta = entryOffset - position.offset
        if delta == 0 { return }
        surface?.scroll(.lines(delta))
    }

    private var entryOffset: Int?
    private var lastPosition: TerminalScrollPosition?

    func report(position: TerminalScrollPosition, from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        lastPosition = position
        if entryOffset == nil { entryOffset = position.offset }
    }

    func end() {
        guard isActive else { return }
        surface?.endSearch()
        teardown()
    }

    func backendEnded(from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        teardown()
    }

    /// Guarded because libghostty calls END_SEARCH back synchronously from `end_search`, re-entering here.
    private func teardown() {
        guard isActive else { return }
        debounce?.cancel()
        debounce = nil
        isActive = false
        if bar?.isFieldFirstResponder == true { surface?.focus() }
        isEditing = false
        needle = ""
        total = nil
        selected = nil
        fieldLanding = nil
        pendingStep = nil
        viewportTopAtStep = nil
        didRequestSelection = false
        didWeighSelection = false
        unsent = nil
        restoreViewport()
        if didStartScrollMode {
            didStartScrollMode = false
            scrollMode.end()
        }
        panel?.setFindFieldShown(false)
        bar = nil
        panel = nil
        surface = nil
        entryOffset = nil
        lastPosition = nil
        Log.info("search closed", category: .panes)
        onActiveChanged?(false)
    }

    func isDriving(_ s: AnyObject) -> Bool { surface === (s as AnyObject) }

    private func needleDidChange(_ text: String) {
        needle = text
        didRequestSelection = false
        didWeighSelection = false
        debounce?.cancel()
        debounce = nil
        guard !text.isEmpty, text.count < Self.debounceBelowLength else {
            unsent = nil
            selected = nil
            fieldLanding = nil
            showCount()
            surface?.search(text)
            return
        }
        unsent = text
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            self.unsent = nil
            self.selected = nil
            fieldLanding = nil
            self.surface?.search(text)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceDelay, execute: work)
    }

    #if DEBUG
        func beginNeedleForTesting(_ text: String) {
            needle = text
            bar?.needle = text
            surface?.search(text)
        }

        func typeForTesting(_ text: String) {
            bar?.needle = text
            needleDidChange(text)
        }

        var didRequestSelectionForTesting: Bool { didRequestSelection }
    #endif

    func report(total: Int?, from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        self.total = total
        showCount()
        guard (total ?? 0) > 0 else {
            restoreViewport()
            return
        }
        selectNewestIfUnselected()
    }

    /// Once per needle: `SEARCH_TOTAL` fires repeatedly as the engine works back through the buffer.
    /// A match already on screen selects nothing, so opening find never scrolls away from what the reader sees.
    private func selectNewestIfUnselected() {
        guard !didRequestSelection, !didWeighSelection, !needle.isEmpty, unsent == nil else { return }
        didWeighSelection = true
        guard !viewportHoldsNeedle() else { return }
        navigate(.next)
    }

    private func viewportHoldsNeedle() -> Bool {
        guard let surface, let grid = surface.grid, let metrics = surface.cellMetrics, grid.rowCount > 0 else {
            return false
        }
        let top = grid.viewportTop
        let bottom = min(top + metrics.rows, grid.rowCount) - 1
        guard
            bottom >= top, let lastRow = grid.row(bottom),
            let text = grid.text(
                from: TerminalGridPoint(row: top, column: 0),
                to: TerminalGridPoint(row: bottom, column: max(lastRow.cells.count - 1, 0)))
        else { return false }
        return text.split(whereSeparator: \.isNewline).contains {
            !Self.occurrenceColumns(of: needle, in: String($0)).isEmpty
        }
    }

    func report(selected: Int?, start: TerminalGridPoint?, from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        self.selected = selected
        showCount()
        guard pendingStep != nil, selected != nil else { return }
        noteViewportMove()
        pendingStep = nil
        viewportTopAtStep = nil
        land(on: start)
    }

    private func showCount() {
        bar?.showCount(total: total, selected: selected)
    }

    /// A selection already on screen moves nothing, and putting the viewport "back" would throw the reader to the bottom.
    private func noteViewportMove() {
        guard let before = viewportTopAtStep, before != surface?.grid?.viewportTop else { return }
        didMoveViewport = true
    }

    private var pendingStep: TerminalSearchStep?

    private var viewportTopAtStep: Int?

    /// Steps from the field mark their match, so a hand-off to scroll mode starts on it wherever output took it.
    private var fieldLanding: TerminalGridMark?

    private func land(on start: TerminalGridPoint?) {
        guard let start else { return }
        if scrollMode.isActive {
            scrollMode.land(on: start)
        } else {
            fieldLanding = surface?.grid?.mark(start)
        }
    }

    private static func viewportRows(of surface: TerminalSurface) -> [String] {
        (0..<(surface.cellMetrics?.rows ?? 0)).map { surface.text(viewportRow: $0) ?? "" }
    }

    private static func occurrenceColumns(of needle: String, in text: String) -> [Int] {
        let haystack = text.map(asciiFolded)
        let pattern = needle.map(asciiFolded)
        guard !pattern.isEmpty, haystack.count >= pattern.count else { return [] }
        return (0...(haystack.count - pattern.count)).filter { start in
            Array(haystack[start..<(start + pattern.count)]) == pattern
        }
    }

    /// Not `lowercased()`: the engine folds ASCII only, and Unicode folding can change a string's length.
    private static func asciiFolded(_ character: Character) -> Character {
        guard let ascii = character.asciiValue, ascii >= UInt8(ascii: "A"), ascii <= UInt8(ascii: "Z")
        else { return character }
        return Character(UnicodeScalar(ascii + 32))
    }

    func handle(_ event: NSEvent) -> Bool {
        guard isActive, !isEditing, scrollMode.isActive, let key = Self.key(for: event) else { return false }
        switch key {
        case .step(let step): navigate(step)
        case .end:
            guard scrollMode.selection == nil else { return false }
            end()
        }
        return true
    }

    /// Declines ⌘ and ⌥ chords: this runs ahead of menu key equivalents.
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

    private static let debounceBelowLength = 3
    private static let debounceDelay: TimeInterval = 0.3
    private static let escapeKeyCode: UInt16 = 53
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
}
