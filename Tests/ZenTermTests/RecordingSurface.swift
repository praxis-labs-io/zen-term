import AppKit
import TerminalKit

final class RecordingSurface: NSObject, TerminalSurface {
    final class ResizingView: NSView {
        var onResize: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            onResize?()
        }
    }

    let resizingView = ResizingView()
    var view: NSView { resizingView }
    weak var delegate: TerminalSurfaceDelegate?
    var title = ""
    private(set) var isFocused = false
    var lastConfig: TerminalSurfaceConfig?
    var currentDirectory: URL?
    var isBusy = false
    var backgroundOverride: TerminalColor?
    var terminated = false
    var failOnStart = false
    private(set) var startCount = 0
    func start(_ config: TerminalSurfaceConfig) {
        startCount += 1
        lastConfig = config
        if let theme = config.theme, let behavior = config.behavior {
            lastAppearance = (theme, behavior)
        }
        if let fontSize = config.fontSize { fontSizes.append(fontSize) }
        if failOnStart {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.surfaceDidFailToStart(self)
            }
        }
    }
    private(set) var lastAppearance: (theme: TerminalTheme, behavior: TerminalBehavior)?
    func applyAppearance(theme: TerminalTheme, behavior: TerminalBehavior) {
        lastAppearance = (theme, behavior)
    }
    private(set) var fontSizes: [CGFloat] = []
    var lastFontSize: CGFloat? { fontSizes.last }
    func setFontSize(_ points: CGFloat) { fontSizes.append(points) }

    private(set) var focusCount = 0
    func focus() {
        resizingView.window?.makeFirstResponder(resizingView)
        isFocused = true
        focusCount += 1
    }
    func terminate() { terminated = true }
    private(set) var focusRenders: [Bool] = []
    func setFocused(_ focused: Bool) { focusRenders.append(focused) }
    private(set) var sizeSyncHolds = 0
    func setSizeSyncSuspended(_ suspended: Bool) { sizeSyncHolds = max(0, sizeSyncHolds + (suspended ? 1 : -1)) }
    private(set) var pastes: [String] = []
    func paste(_ text: String) { pastes.append(text) }
    var selectionText: String?
    func copySelection() -> String? { selectionText }
    private(set) var scrolls: [TerminalScroll] = []
    func scroll(_ command: TerminalScroll) { scrolls.append(command) }

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

    var echoesEndSearch = false
    func endSearch() {
        endSearchCount += 1
        if echoesEndSearch { delegate?.surfaceDidEndSearch(self) }
    }

    private(set) var modifierKeyCodes: [UInt16] = []
    func modifiersDidChange(_ event: NSEvent) { modifierKeyCodes.append(event.keyCode) }

    var cellMetrics: TerminalCellMetrics? = TerminalCellMetrics(
        columns: 80, rows: 24, cellWidth: 8, cellHeight: 16, gridInset: 2)

    var selectionOrigin: TerminalViewportCell?

    var rows: [String] = {
        var rows = Array(repeating: "", count: 24)
        rows[2] = "❯ seq 1 3"
        rows[3] = "1"
        rows[4] = "2"
        rows[5] = "3"
        rows[6] = ""
        rows[7] = "❯ echo hi"
        rows[8] = "hi"
        rows[9] = ""
        rows[10] = "~/bin"
        rows[11] = "❯"
        return rows
    }()

    func text(viewportRow row: Int) -> String? {
        guard row < (cellMetrics?.rows ?? rows.count), rows.indices.contains(row) else { return nil }
        return text(
            in: TerminalViewportRange(
                startRow: row, startColumn: 0, endRow: row,
                endColumn: max((cellMetrics?.columns ?? rows[row].count) - 1, 0)))
    }

    static let unwritten: Character = "\0"

    private static func width(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
            0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60,
            0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    func text(in range: TerminalViewportRange) -> String? {
        guard rows.indices.contains(range.startRow), rows.indices.contains(range.endRow) else {
            return nil
        }
        let sliced = (range.startRow...range.endRow).map { row -> String in
            let from = row == range.startRow ? range.startColumn : 0
            let through = row == range.endRow ? range.endColumn : Int.max
            var cell = 0
            var taken = ""
            var blanks = 0
            for character in rows[row] {
                let last = cell + Self.width(character) - 1
                defer { cell = last + 1 }
                guard cell <= through, last >= from else { continue }
                guard character != Self.unwritten else {
                    blanks += 1
                    continue
                }
                taken += String(repeating: " ", count: blanks)
                blanks = 0
                taken.append(character)
            }
            return taken
        }
        return sliced.joined(separator: "\n")
    }
}
