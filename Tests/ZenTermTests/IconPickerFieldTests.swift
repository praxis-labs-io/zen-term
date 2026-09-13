import AppKit
import XCTest

@testable import ZenTerm

final class IconPickerFieldTests: WindowTestCase {
    func test_removingHostFromWindow_closesOpenGrid() {
        let field = IconPickerField(selected: "hammer")
        field.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(host)
        host.addSubview(field)
        field.frame = NSRect(x: 20, y: 300, width: 220, height: 30)
        window.makeFirstResponder(field)
        field.openForTesting()
        XCTAssertTrue(field.isPopoverOpen)
        XCTAssertTrue(window.contentView!.subviews.contains { $0 is ShadowCardView })

        host.removeFromSuperview()

        XCTAssertFalse(field.isPopoverOpen, "grid closes when the field leaves the window")
        XCTAssertFalse(
            window.contentView!.subviews.contains { $0 is ShadowCardView },
            "no orphaned grid card left drawn on the content view")
    }

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

    func test_movingDownFromTheLastSymbolRow_keepsTheColumnInTheBrands() {
        let columns = IconPickerField.columnsForTesting
        let column = 2
        let rows = (IconCatalog.symbols.count + columns - 1) / columns
        let index = (rows - 1) * columns + column
        XCTAssertLessThan(index, IconCatalog.symbols.count, "the last row must reach this column")
        let (field, _) = openedField(selected: IconCatalog.symbols[index])

        field.moveVerticallyForTesting(1)

        XCTAssertEqual(
            field.highlightedSymbolForTesting, IconCatalog.brands[column],
            "Down from column \(column) of the last symbol row should hold that column in the brands")
    }

    func test_withACustomSection_downLandsDirectlyBelow() {
        let (field, _) = openedField(selected: "heart.fill")
        XCTAssertEqual(field.highlightedSymbolForTesting, "heart.fill", "opens on the custom cell")

        field.moveVerticallyForTesting(1)

        XCTAssertEqual(
            field.highlightedSymbolForTesting, IconCatalog.symbols[0],
            "Down from the one-cell Current row must land on the first symbol, not skew across it")
    }

    func test_withACustomSection_upFromAWideRowLandsOnTheShortRowsOnlyCell() {
        let (field, _) = openedField(selected: "heart.fill")
        field.moveVerticallyForTesting(1)
        field.moveHighlightForTesting(5)
        XCTAssertEqual(field.highlightedSymbolForTesting, IconCatalog.symbols[5])

        field.moveVerticallyForTesting(-1)

        XCTAssertEqual(
            field.highlightedSymbolForTesting, "heart.fill",
            "Up onto a one-cell row must land on that cell, not fall off it")
    }

    func test_customSymbol_opensHighlighted() {
        let (field, _) = openedField(selected: "heart.fill")
        XCTAssertEqual(field.highlightedSymbolForTesting, "heart.fill")
    }

    func test_resizingTheWindow_closesTheGrid() {
        let (field, window) = openedField(selected: IconCatalog.defaultSymbol, windowHeight: 900)
        XCTAssertTrue(field.isPopoverOpen, "precondition: the grid is up before the resize")

        window.setFrame(NSRect(x: 0, y: 0, width: 520, height: 400), display: false)

        XCTAssertFalse(field.isPopoverOpen, "the grid must close rather than strand itself")
        XCTAssertFalse(
            window.contentView!.subviews.contains { $0 is ShadowCardView },
            "no card left drawn on the content view after the resize")
    }

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

    func test_inATallWindow_theCardHugsItsContent() throws {
        let (field, window) = openedField(selected: IconCatalog.defaultSymbol, windowHeight: 900)
        let card = try XCTUnwrap(
            window.contentView?.subviews.first { $0 is ShadowCardView }, "no grid card")
        let stack = try XCTUnwrap(
            card.firstDescendant { $0 is NSStackView && $0.subviews.count > 2 }, "no grid stack")
        _ = field

        XCTAssertEqual(
            card.frame.height, stack.fittingSize.height + 16, accuracy: 0.5,
            "card \(card.frame.height) against content \(stack.fittingSize.height) + 16pt of inset")
    }

    func test_theScrollerGetsItsOwnLane_onlyWhenTheGridScrolls() throws {
        let (_, tall) = openedField(selected: IconCatalog.defaultSymbol, windowHeight: 900)
        let roomy = try XCTUnwrap(tall.contentView?.subviews.first { $0 is ShadowCardView })
        let (_, short) = openedField(selected: IconCatalog.defaultSymbol, windowHeight: 300)
        let clamped = try XCTUnwrap(short.contentView?.subviews.first { $0 is ShadowCardView })

        XCTAssertGreaterThan(
            clamped.frame.width, roomy.frame.width,
            "a scrolling grid must widen, or the bar overlays the glyphs")
        XCTAssertGreaterThanOrEqual(clamped.frame.width - roomy.frame.width, 12)
    }

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

extension NSView {
    fileprivate func firstDescendant(_ match: (NSView) -> Bool) -> NSView? {
        var queue = subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if match(view) { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
