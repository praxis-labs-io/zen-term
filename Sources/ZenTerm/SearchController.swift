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
        case selected(Int?)
        case ended
        case wanted(needle: String)
    }

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

    private(set) var isActive = false

    private(set) var isEditing = false

    private weak var surface: (AnyObject & TerminalSurface)?
    private weak var panel: TerminalModeHost?
    private weak var bar: FindBarView?

    private var needle = ""
    private var total: Int?
    private var selected: Int?
    private var debounce: DispatchWorkItem?

    /// The needle itself rather than a work item, so a commit cannot re-send one libghostty already has.
    private var unsent: String?

    private var hasPreviewed = false

    /// `selected` lags the backend, so a Return before its report would otherwise step twice.
    private var didRequestSelection = false

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
            isEditing = true
            bar?.focusField()
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

        if !scrollMode.isActive { panel.modeMeta = PanelMeta(title: "Find", action: .toggleSearch) }

        settleLayout()

        bar?.focusField()
        Log.info("search opened", category: .panes)
        onActiveChanged?(true)

        needle = seed
        if !seed.isEmpty { surface.search(seed) }
    }

    /// Steps unless a preview already picked a match: libghostty matches eagerly but selects nothing.
    func commit() {
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
        if selected != nil { land(after: .next) }
    }

    private func flushPendingNeedle() {
        guard let text = unsent else { return }
        debounce?.cancel()
        debounce = nil
        unsent = nil
        selected = nil
        didRequestSelection = false
        surface?.search(text)
    }

    func navigate(_ step: TerminalSearchStep) {
        guard isActive, !needle.isEmpty else { return }
        pendingStep = step
        didMoveViewport = true
        didRequestSelection = true
        rowsAtStep = surface.map(Self.viewportRows(of:))
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
        pendingStep = nil
        rowsAtStep = nil
        hasPreviewed = false
        didRequestSelection = false
        unsent = nil
        restoreViewport()
        if didStartScrollMode {
            didStartScrollMode = false
            scrollMode.end()
        }
        if !scrollMode.isActive { panel?.modeMeta = nil }
        panel?.setFindBarShown(false)
        settleLayout()
        bar = nil
        panel = nil
        surface = nil
        entryOffset = nil
        lastPosition = nil
        Log.info("search closed", category: .panes)
        onActiveChanged?(false)
    }

    func isDriving(_ s: AnyObject) -> Bool { surface === (s as AnyObject) }

    private func settleLayout() {
        panel?.layoutSubtreeIfNeeded()
        scrollMode.refreshGeometry()
    }

    private func needleDidChange(_ text: String) {
        needle = text
        hasPreviewed = false
        didRequestSelection = false
        debounce?.cancel()
        debounce = nil
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
        func beginNeedleForTesting(_ text: String) {
            needle = text
            bar?.needle = text
            surface?.search(text)
        }

        func typeForTesting(_ text: String) {
            bar?.needle = text
            needleDidChange(text)
        }
    #endif

    func report(total: Int?, from s: AnyObject) {
        guard isActive, isDriving(s) else { return }
        self.total = total
        showCount()
        guard (total ?? 0) > 0 else {
            hasPreviewed = false
            restoreViewport()
            return
        }
        previewIfNothingVisible()
    }

    /// Latched once per needle: `SEARCH_TOTAL` fires repeatedly as the engine works back through the buffer.
    private func previewIfNothingVisible() {
        guard isEditing, !hasPreviewed, (total ?? 0) > 0, !needle.isEmpty else { return }
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
        bar?.showCount(total: total, selected: isEditing ? nil : selected)
    }

    private var pendingStep: TerminalSearchStep?

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

    /// Compared by screen, not offset: the scrollbar report lags the selected index by a frame or more.
    private var rowsAtStep: [String]?

    static func matchCell(
        needle: String, rows: [String], from cursor: ScrollCell, step: TerminalSearchStep,
        viewportMoved: Bool, selected: Int?, total: Int?
    ) -> ScrollCell? {
        guard !needle.isEmpty else { return nil }
        let occurrences = rows.enumerated().flatMap { row, text in
            occurrenceColumns(of: needle, in: text).map { ScrollCell(row: row, column: $0) }
        }
        guard !occurrences.isEmpty else { return nil }
        if viewportMoved {
            let onTopRow = occurrences.filter { $0.row == 0 }
            if !onTopRow.isEmpty { return step == .next ? onTopRow.last : onTopRow.first }
            if let clamped = clampedMatch(
                in: occurrences, step: step, selected: selected, total: total)
            {
                return clamped
            }
            return step == .next ? occurrences.first : occurrences.last
        }
        let before = occurrences.filter {
            $0.row < cursor.row || ($0.row == cursor.row && $0.column < cursor.column)
        }
        let after = occurrences.filter {
            $0.row > cursor.row || ($0.row == cursor.row && $0.column > cursor.column)
        }
        return (step == .next ? before.last ?? occurrences.first : after.first ?? occurrences.last)
    }

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
        guard isActive, !isEditing, let key = Self.key(for: event) else { return false }
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
