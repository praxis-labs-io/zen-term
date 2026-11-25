import AppKit
import XCTest

@testable import ZenTerm

final class PaletteShellTests: WindowTestCase {
    private final class StubPalette: PaletteOverlay {
        struct Entry {
            let title: String
            let action: String?
            let hasMoreActions: Bool
        }

        let all: [Entry]
        private(set) var shown: [Entry]

        init(_ entries: [Entry]) {
            all = entries
            shown = entries
            super.init(placeholder: "Search stubs", emptyText: "No stubs", rowHeight: ChromeMetrics.Height.lg) {}
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func numberOfRows() -> Int { shown.count }

        override func makeRow(at index: Int) -> PaletteRowView {
            SelectableRowView(ListRow.Content(title: shown[index].title))
        }

        override func applyFilter(query: String) {
            shown = query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }

        override func activate(index: Int, modifiers: NSEvent.ModifierFlags) {}

        override func returnAction(at index: Int) -> String? { shown[index].action }

        override func hasMoreActions(at index: Int) -> Bool { shown[index].hasMoreActions }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func mount(_ overlay: PaletteOverlay) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 560), styleMask: [.borderless],
            backing: .buffered, defer: false)
        overlay.translatesAutoresizingMaskIntoConstraints = true
        window.contentView?.addSubview(overlay)
        overlay.frame = window.contentView?.bounds ?? .zero
        overlay.layoutSubtreeIfNeeded()
        return window
    }

    private func searchField(in overlay: PaletteOverlay) throws -> NSTextField {
        try XCTUnwrap(
            descendants(of: overlay).compactMap { $0 as? NSTextField }.first { $0.delegate === overlay })
    }

    private func bar(in overlay: PaletteOverlay) throws -> HintFooter {
        try XCTUnwrap(descendants(of: overlay).compactMap { $0 as? HintFooter }.first)
    }

    private func barText(in overlay: PaletteOverlay) throws -> [String] {
        func read(_ view: NSView) -> [String] {
            if view.isHidden { return [] }
            if let keycap = view as? KeycapView { return [keycap.shortcut] }
            if let label = view as? NSTextField { return [label.stringValue] }
            return view.subviews.flatMap(read)
        }
        return read(try bar(in: overlay))
    }

    private func press(_ selector: Selector, in overlay: PaletteOverlay) throws {
        _ = overlay.control(try searchField(in: overlay), textView: NSTextView(), doCommandBy: selector)
    }

    private func type(_ query: String, into overlay: PaletteOverlay) throws {
        let field = try searchField(in: overlay)
        field.stringValue = query
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func makeStub() -> StubPalette {
        StubPalette([
            .init(title: "Alpha", action: "Run", hasMoreActions: false),
            .init(title: "Beta", action: "Open", hasMoreActions: true),
            .init(title: "Gamma", action: "Switch", hasMoreActions: false),
        ])
    }

    func test_theBar_namesTheSelectedRowsReturnAction_labelThenKey() throws {
        let overlay = makeStub()
        _ = mount(overlay)

        XCTAssertEqual(try barText(in: overlay), ["Run", "⏎"])
    }

    func test_theBar_followsTheSelection_showingActionsOnlyWhereARowHasMore() throws {
        let overlay = makeStub()
        _ = mount(overlay)

        try press(#selector(NSResponder.moveDown(_:)), in: overlay)
        XCTAssertEqual(try barText(in: overlay), ["Open", "⏎", "Actions", "⌘K"])

        try press(#selector(NSResponder.moveDown(_:)), in: overlay)
        XCTAssertEqual(try barText(in: overlay), ["Switch", "⏎"], "Actions leaves with the row that had it")

        try press(#selector(NSResponder.moveUp(_:)), in: overlay)
        XCTAssertEqual(try barText(in: overlay), ["Open", "⏎", "Actions", "⌘K"])
    }

    func test_theBar_followsThePointer() throws {
        let overlay = makeStub()
        _ = mount(overlay)
        let rows = descendants(of: overlay).compactMap { $0 as? SelectableRowView }

        rows[2].onPointerEnter?()

        XCTAssertEqual(try barText(in: overlay), ["Switch", "⏎"])
    }

    func test_theBar_followsTheFilter_andEmptiesWithNoMatch() throws {
        let overlay = makeStub()
        _ = mount(overlay)

        try type("gam", into: overlay)
        XCTAssertEqual(try barText(in: overlay), ["Switch", "⏎"])

        try type("zzz", into: overlay)
        XCTAssertEqual(try barText(in: overlay), [], "nothing to run, so the bar names nothing")
    }

    func test_theBar_isRightAligned() throws {
        let overlay = makeStub()
        _ = mount(overlay)
        let bar = try bar(in: overlay)
        let key = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? KeycapView }.last)

        XCTAssertEqual(
            overlay.card.convert(key.bounds, from: key).maxX, overlay.card.bounds.maxX - ChromeMetrics.Spacing.s12,
            accuracy: 0.5, "the bar's last key sits on the search row's trailing inset")
    }

    func test_theSearchFieldsTrailingSlot_sitsAfterTheField_andTheFieldStillTakesTyping() throws {
        let overlay = makeStub()
        let window = mount(overlay)
        let tip = NSTextField(labelWithString: "New")
        overlay.searchAccessory = tip
        overlay.layoutSubtreeIfNeeded()
        let field = try searchField(in: overlay)

        XCTAssertTrue(tip.isDescendant(of: overlay.card), "the slot's view is not in the panel")
        let fieldFrame = overlay.card.convert(field.bounds, from: field)
        let tipFrame = overlay.card.convert(tip.bounds, from: tip)
        XCTAssertGreaterThanOrEqual(tipFrame.minX, fieldFrame.maxX, "the slot sits after the field")
        XCTAssertLessThanOrEqual(tipFrame.maxX, overlay.card.bounds.maxX, "the slot runs off the panel")
        XCTAssertEqual(tipFrame.midY, fieldFrame.midY, accuracy: 1, "the slot sits on the field's line")

        overlay.focusQuery()
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === field, "the field lost the keyboard")
        try type("bet", into: overlay)
        XCTAssertEqual(try barText(in: overlay), ["Open", "⏎", "Actions", "⌘K"], "typing no longer filters")
    }

    func test_replacingTheTrailingSlot_dropsTheOldView() {
        let overlay = makeStub()
        _ = mount(overlay)
        let first = NSView()
        let second = NSView()

        overlay.searchAccessory = first
        overlay.searchAccessory = second

        XCTAssertNil(first.superview)
        XCTAssertTrue(second.isDescendant(of: overlay.card))

        overlay.searchAccessory = nil
        XCTAssertNil(second.superview)
    }
}
