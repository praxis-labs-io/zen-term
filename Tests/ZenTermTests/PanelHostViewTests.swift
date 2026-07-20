import AppKit
import XCTest

@testable import ZenTerm

/// ZEN-65 replaced the floating corner icons with a real header: a drawer shows its title +
/// keybind always (swapping the right side to an "Exit Focus Mode" ⌘F action while zoomed); a
/// pane shows a "Terminal pane" + "Exit Focus Mode" ⌘F header only while zoomed. Per the house
/// rule "GUI controls need interaction tests", these mount the panel and drive its zoom state.
final class PanelHostViewTests: XCTestCase {
    private func mount(_ panel: PanelHostView) {
        panel.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(panel)
        panel.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        panel.layoutSubtreeIfNeeded()
    }

    func test_drawerMeta_showsHeaderImmediately() {
        let panel = PanelHostView(
            content: NSView(), background: Theme.current.chrome.background.nsColor,
            meta: PanelMeta(title: "Bottom drawer", action: .toggleBottomDrawer),
            onFocusRequest: {})
        mount(panel)
        XCTAssertTrue(panel.isHeaderVisibleForTesting, "a drawer's header is always shown")
    }

    func test_zoomMeta_headerHiddenUntilZoom() {
        let panel = PanelHostView(
            content: NSView(), background: Theme.current.chrome.background.nsColor,
            meta: nil,
            zoomMeta: PanelMeta(title: "Terminal pane", action: .toggleZoom, actionLabel: "Exit Focus Mode"),
            onFocusRequest: {})
        mount(panel)
        XCTAssertFalse(panel.isHeaderVisibleForTesting, "a pane's Focus Mode header is hidden until zoom")

        panel.isZoomed = true
        XCTAssertTrue(panel.isHeaderVisibleForTesting, "zooming a pane reveals its Focus Mode header")

        panel.isZoomed = false
        XCTAssertFalse(panel.isHeaderVisibleForTesting, "unzooming hides it again")
    }

    func test_drawerZoom_swapsHeaderToFocusModeAndCommandF() {
        let panel = PanelHostView(
            content: NSView(), background: Theme.current.chrome.background.nsColor,
            meta: PanelMeta(title: "Bottom drawer", action: .toggleBottomDrawer),
            zoomMeta: PanelMeta(title: "Bottom drawer", action: .toggleZoom, actionLabel: "Exit Focus Mode"),
            onFocusRequest: {})
        mount(panel)

        // Resting: the drawer's own title + toggle keybind, no action label.
        XCTAssertTrue(panel.isHeaderVisibleForTesting, "a drawer's header is always shown")
        XCTAssertEqual(panel.headerContentForTesting?.title, "BOTTOM DRAWER")
        XCTAssertNil(panel.headerActionLabelForTesting, "resting header has no action label")
        let restingShortcut = panel.headerContentForTesting?.shortcut
        XCTAssertEqual(restingShortcut, CommandCatalog.spec(for: .toggleBottomDrawer).shortcut)

        // Zoomed: the title stays the drawer's own; the right side swaps to "Exit Focus Mode" + ⌘F.
        panel.isZoomed = true
        XCTAssertTrue(panel.isHeaderVisibleForTesting, "a zoomed drawer keeps its header")
        XCTAssertEqual(panel.headerContentForTesting?.title, "BOTTOM DRAWER")
        XCTAssertEqual(panel.headerActionLabelForTesting, "EXIT FOCUS MODE")
        XCTAssertEqual(panel.headerContentForTesting?.shortcut, CommandCatalog.spec(for: .toggleZoom).shortcut)

        // Unzoom restores the resting title + keybind, dropping the action label.
        panel.isZoomed = false
        XCTAssertEqual(panel.headerContentForTesting?.title, "BOTTOM DRAWER")
        XCTAssertNil(panel.headerActionLabelForTesting)
        XCTAssertEqual(panel.headerContentForTesting?.shortcut, restingShortcut)
    }

    func test_noMeta_neverShowsHeader() {
        let panel = PanelHostView(
            content: NSView(), background: Theme.current.chrome.background.nsColor,
            meta: nil, onFocusRequest: {})
        mount(panel)
        XCTAssertFalse(panel.isHeaderVisibleForTesting)
        panel.isZoomed = true  // no zoomMeta supplied → still nothing to show
        XCTAssertFalse(panel.isHeaderVisibleForTesting)
    }
}
