import AppKit
import XCTest

@testable import ZenTerm

/// ZEN-65 replaced the floating corner icons with a real header: a drawer shows its title +
/// keybind always (swapping to a "<drawer>: Focus Mode" ⌘F variant while zoomed); a pane shows a
/// "Terminal pane: Focus Mode" header only while zoomed. Per the house rule "GUI controls need
/// interaction tests", these mount the panel and drive its zoom state.
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
            meta: nil, zoomMeta: PanelMeta(title: "Terminal pane: Focus Mode", action: .toggleZoom),
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
            zoomMeta: PanelMeta(title: "Bottom drawer: Focus Mode", action: .toggleZoom),
            onFocusRequest: {})
        mount(panel)

        // Resting: the drawer's own title + toggle keybind.
        XCTAssertTrue(panel.isHeaderVisibleForTesting, "a drawer's header is always shown")
        XCTAssertEqual(panel.headerContentForTesting?.title, "BOTTOM DRAWER")
        let restingShortcut = panel.headerContentForTesting?.shortcut
        XCTAssertEqual(restingShortcut, CommandCatalog.spec(for: .toggleBottomDrawer).shortcut)

        // Zoomed: the header stays visible but swaps to the Focus Mode variant + ⌘F.
        panel.isZoomed = true
        XCTAssertTrue(panel.isHeaderVisibleForTesting, "a zoomed drawer keeps its header")
        XCTAssertEqual(panel.headerContentForTesting?.title, "BOTTOM DRAWER: FOCUS MODE")
        XCTAssertEqual(panel.headerContentForTesting?.shortcut, CommandCatalog.spec(for: .toggleZoom).shortcut)

        // Unzoom restores the resting title + keybind.
        panel.isZoomed = false
        XCTAssertEqual(panel.headerContentForTesting?.title, "BOTTOM DRAWER")
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
