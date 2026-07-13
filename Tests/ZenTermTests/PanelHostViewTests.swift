import AppKit
import XCTest

@testable import ZenTerm

/// ZEN-65 replaced the floating corner icons with a real header: a drawer shows its title +
/// keybind always; a pane shows a "Full screen" header only while zoomed. Per the house rule
/// "GUI controls need interaction tests", these mount the panel and drive its zoom state.
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
            meta: nil, zoomMeta: PanelMeta(title: "Full screen", action: .toggleZoom),
            onFocusRequest: {})
        mount(panel)
        XCTAssertFalse(panel.isHeaderVisibleForTesting, "a pane's full-screen header is hidden until zoom")

        panel.isZoomed = true
        XCTAssertTrue(panel.isHeaderVisibleForTesting, "zooming a pane reveals its full-screen header")

        panel.isZoomed = false
        XCTAssertFalse(panel.isHeaderVisibleForTesting, "unzooming hides it again")
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
