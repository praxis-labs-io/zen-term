import AppKit
import XCTest

@testable import ZenTerm

final class DropdownTests: WindowTestCase {
    func test_selectedIndex_reflectsInitAndSetItems() {
        let items = [
            DropdownItem(title: "A", group: nil, note: nil, isSelected: true),
            DropdownItem(title: "B", group: "G", note: "dark", isSelected: false),
        ]
        let dropdown = Dropdown(items: items, selectedIndex: 0) { _ in }
        XCTAssertEqual(dropdown.selectedIndex, 0)

        dropdown.setItems(items, selectedIndex: 1)
        XCTAssertEqual(dropdown.selectedIndex, 1)
    }

    func test_titleShowsSelectedItem() {
        let items = [
            DropdownItem(title: "Rosé Pine Moon", group: nil, note: nil, isSelected: true),
            DropdownItem(title: "Nord", group: "Bundled", note: "dark", isSelected: false),
        ]
        let dropdown = Dropdown(items: items, selectedIndex: 1) { _ in }
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Nord")
    }

    func test_openList_producesVisibleCard() {
        let items = [
            DropdownItem(title: "Rosé Pine Moon", group: nil, note: nil, isSelected: true),
            DropdownItem(title: "Nord", group: "Bundled", note: "Dark", isSelected: false),
            DropdownItem(title: "Catppuccin Mocha", group: "Bundled", note: "Dark", isSelected: false),
        ]
        let dropdown = Dropdown(items: items, selectedIndex: 0) { _ in }
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 200, width: 220, height: 30)

        dropdown.openListForTesting()

        XCTAssertTrue(dropdown.isPopoverOpen)
        // The regression: the card must have real size, not collapse to ~zero (invisible list).
        XCTAssertGreaterThan(dropdown.listCardSizeForTesting.height, 0)
        XCTAssertGreaterThan(dropdown.listCardSizeForTesting.width, 0)
    }

    /// A bare Esc over an open list closes it at the real dispatch layer — the dropdown's own
    /// `keyDown`, which AppKit reaches before any card-root `performKeyEquivalent` (confirmed
    /// in the running app). The event is built the way AppKit delivers a bare Esc (keyCode 53, no
    /// modifiers). Driving the real keyDown is the point: a `performKeyEquivalent`-by-hand test would
    /// pass even with this handler gone, since that layer never runs for a bare Esc while the
    /// dropdown holds focus.
    func test_escKeyDown_closesOpenList() {
        let items = [
            DropdownItem(title: "A", group: nil, note: nil, isSelected: true),
            DropdownItem(title: "B", group: nil, note: nil, isSelected: false),
        ]
        let dropdown = Dropdown(items: items, selectedIndex: 0) { _ in }
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 200, width: 220, height: 30)
        window.makeFirstResponder(dropdown)
        dropdown.openListForTesting()
        XCTAssertTrue(dropdown.isPopoverOpen)

        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        dropdown.keyDown(with: esc)

        XCTAssertFalse(dropdown.isPopoverOpen, "Esc in the dropdown's keyDown closes the list")
    }

    /// The open list card lives on `window.contentView`, not inside the dropdown's own
    /// subtree, so tearing the dropdown's host out of the window (what a tab-switch `closeModal()`
    /// does to the Settings card) must still take the card with it. Without a leave-the-window hook
    /// the card orphans on the content view — stuck on every tab, no way to clear but restart.
    func test_removingHostFromWindow_closesOpenList() {
        let items = [
            DropdownItem(title: "A", group: nil, note: nil, isSelected: true),
            DropdownItem(title: "B", group: nil, note: nil, isSelected: false),
        ]
        let dropdown = Dropdown(items: items, selectedIndex: 0) { _ in }
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        // Host the dropdown inside a container standing in for the Settings modal overlay, so the
        // teardown removes an ANCESTOR of the dropdown (not the dropdown directly) — exactly the
        // `closeModal()` path.
        let host = NSView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(host)
        host.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 200, width: 220, height: 30)
        window.makeFirstResponder(dropdown)
        dropdown.openListForTesting()
        XCTAssertTrue(dropdown.isPopoverOpen)
        XCTAssertTrue(window.contentView!.subviews.contains { $0 is ShadowCardView })

        host.removeFromSuperview()  // the Settings card being torn down out from under the dropdown

        XCTAssertFalse(dropdown.isPopoverOpen, "list closes when the dropdown leaves the window")
        XCTAssertFalse(
            window.contentView!.subviews.contains { $0 is ShadowCardView },
            "no orphaned list card left drawn on the content view")
    }

    func test_arrowNavigation_scrollsHighlightIntoView() {
        // 15 rows overflow the ~260pt list cap, so the last row starts below the fold.
        let items = (0..<15).map {
            DropdownItem(title: "Theme \($0)", group: nil, note: nil, isSelected: $0 == 0)
        }
        let dropdown = Dropdown(items: items, selectedIndex: 0) { _ in }
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 20, y: 400, width: 220, height: 30)

        dropdown.openListForTesting()
        // Walk the highlight down to the last item, past the visible cap.
        for _ in 0..<(items.count - 1) { dropdown.moveHighlightForTesting(1) }

        // Regression: the highlighted row must have been scrolled into view, not left below the fold.
        XCTAssertTrue(dropdown.isHighlightedRowVisibleForTesting)
    }
}
