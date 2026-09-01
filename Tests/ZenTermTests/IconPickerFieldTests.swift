import AppKit
import XCTest

@testable import ZenTerm

final class IconPickerFieldTests: WindowTestCase {
    /// Same class as `Dropdown`: the open grid card lives on `window.contentView`, not
    /// inside the field's own subtree, so tearing the field's host out of the window — what a
    /// tab-switch `closeModal()` does to the workspace / tool-float form hosting this field — must
    /// still take the card with it. Without a leave-the-window hook the grid orphans on the content
    /// view, stuck over every tab with no way to clear but restart.
    func test_removingHostFromWindow_closesOpenGrid() {
        let field = IconPickerField(selected: "hammer")
        field.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        // Host the field inside a container standing in for the form overlay, so the teardown
        // removes an ANCESTOR of the field (not the field directly) — the `closeModal()` path.
        let host = NSView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(host)
        host.addSubview(field)
        field.frame = NSRect(x: 20, y: 300, width: 220, height: 30)
        window.makeFirstResponder(field)
        field.openForTesting()
        XCTAssertTrue(field.isPopoverOpen)
        XCTAssertTrue(window.contentView!.subviews.contains { $0 is ShadowCardView })

        host.removeFromSuperview()  // the form being torn down out from under the field

        XCTAssertFalse(field.isPopoverOpen, "grid closes when the field leaves the window")
        XCTAssertFalse(
            window.contentView!.subviews.contains { $0 is ShadowCardView },
            "no orphaned grid card left drawn on the content view")
    }

    /// Drive the real control in a real window: the grid is sectioned now, and a heading is a row
    /// in the stack. If headings ever became cells, the highlight would land on one and Return
    /// would commit a title as a symbol.
    func test_arrowNav_neverLandsOnASectionHeading() {
        let (field, _) = openedField(selected: IconCatalog.defaultSymbol)
        XCTAssertEqual(
            field.cellCountForTesting, IconCatalog.all.count,
            "one cell per roster symbol — a heading must not have become one")

        for _ in 0..<IconCatalog.all.count + 4 {
            field.moveHighlightForTesting(1)
            let symbol = field.highlightedSymbolForTesting
            XCTAssertNotNil(symbol)
            XCTAssertTrue(
                IconCatalog.all.contains(symbol ?? ""),
                "highlight landed on \(symbol ?? "nil"), which is not a roster symbol")
        }
    }

    /// The symbols block is a whole number of rows precisely so Down crosses into the brands
    /// without skewing. Walking off the end of the last symbols row must land in the same column
    /// of the first brands row.
    func test_movingDownFromTheLastSymbolRow_keepsTheColumnInTheBrands() {
        let columns = IconPickerField.columnsForTesting
        let column = 2
        // Anchor on the grid position, not on `count - columns`: that expression slides with the
        // roster size and would keep this test green on a count that actually skews.
        let rows = (IconCatalog.symbols.count + columns - 1) / columns
        let index = (rows - 1) * columns + column
        XCTAssertLessThan(index, IconCatalog.symbols.count, "the last row must reach this column")
        let (field, _) = openedField(selected: IconCatalog.symbols[index])

        field.moveHighlightForTesting(columns)

        XCTAssertEqual(
            field.highlightedSymbolForTesting, IconCatalog.brands[column],
            "Down from column \(column) of the last symbol row should hold that column in the brands")
    }

    /// A float pinned off the roster opens with its own symbol highlighted, not the default.
    func test_customSymbol_opensHighlighted() {
        let (field, _) = openedField(selected: "heart.fill")
        XCTAssertEqual(field.highlightedSymbolForTesting, "heart.fill")
    }

    /// In a window with room, the whole roster is on screen at once — 67 cells and two headings
    /// is a tall card, and truncating it hid the brand marks below a scroll.
    func test_inATallWindow_theGridIsNotTruncated() throws {
        let (field, window) = openedField(selected: IconCatalog.defaultSymbol, windowHeight: 900)
        let card = try XCTUnwrap(
            window.contentView?.subviews.first { $0 is ShadowCardView }, "no grid card")
        _ = field

        XCTAssertGreaterThan(card.frame.height, 400, "the grid is being cut short in a tall window")
        XCTAssertLessThan(
            card.frame.maxY, window.contentView!.bounds.height,
            "the card runs past the top of the window")
    }

    /// The clamp still has to hold, or a short window gets a card drawn off its own edge.
    func test_inAShortWindow_theCardStaysInside() throws {
        let (field, window) = openedField(selected: IconCatalog.defaultSymbol, windowHeight: 300)
        let card = try XCTUnwrap(
            window.contentView?.subviews.first { $0 is ShadowCardView }, "no grid card")
        _ = field

        XCTAssertLessThanOrEqual(card.frame.height, window.contentView!.bounds.height)
        XCTAssertGreaterThanOrEqual(card.frame.minY, 0)
        XCTAssertLessThanOrEqual(card.frame.maxY, window.contentView!.bounds.height)
    }

    @discardableResult
    private func openedField(
        selected: String, windowHeight: CGFloat = 400
    ) -> (IconPickerField, NSWindow) {
        let field = IconPickerField(selected: selected)
        field.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: windowHeight),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(field)
        field.frame = NSRect(x: 20, y: windowHeight - 100, width: 220, height: 30)
        window.makeFirstResponder(field)
        field.openForTesting()
        return (field, window)
    }
}
