import AppKit
import XCTest

@testable import ZenTerm

final class PanelHostViewTests: WindowTestCase {
    private var originalConfig: GeneralConfig!
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDown() {
        GeneralConfig.setCurrentForTesting(originalConfig)
        super.tearDown()
    }

    private func mount(_ panel: PanelHostView) {
        panel.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(panel)
        panel.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        panel.layoutSubtreeIfNeeded()
    }

    private func paintedAlpha(of view: NSView, at point: NSPoint) -> CGFloat {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.alphaComponent ?? -1
    }

    func test_focus_bordersThePaneInAccentAt2pt_andBlurRestoresTheRestEdge() throws {
        let focused = PanelHostView(content: NSView(), meta: nil, onFocusRequest: {})
        let unfocused = PanelHostView(content: NSView(), meta: nil, onFocusRequest: {})
        mount(focused)
        mount(unfocused)
        let chrome = Theme.current.chrome
        let rest = chrome.fill(alpha: ChromeTheme.hairline).cgColor

        focused.isFocused = true

        XCTAssertEqual(focused.borderForTesting.color, chrome.accent.nsColor.cgColor)
        XCTAssertEqual(focused.borderForTesting.width, ChromeMetrics.Border.paneFocus)
        XCTAssertEqual(ChromeMetrics.Border.paneFocus, 2)
        XCTAssertEqual(unfocused.borderForTesting.color, rest, "an unfocused pane keeps its hairline edge")
        XCTAssertEqual(unfocused.borderForTesting.width, ChromeMetrics.Border.width)

        focused.isFocused = false

        XCTAssertEqual(focused.borderForTesting.color, rest, "blur restores the hairline edge")
        XCTAssertEqual(focused.borderForTesting.width, ChromeMetrics.Border.width)
    }

    func test_focus_paintsNothingOutsideThePane() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        host.wantsLayer = true
        let panel = PanelHostView(content: NSView(), meta: nil, onFocusRequest: {})
        panel.translatesAutoresizingMaskIntoConstraints = true
        window = NSWindow(
            contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(host)
        host.addSubview(panel)
        panel.frame = host.bounds.insetBy(dx: 40, dy: 40)
        panel.isFocused = true
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            paintedAlpha(of: host, at: NSPoint(x: panel.frame.minX - 3, y: host.bounds.midY)), 0,
            accuracy: 0.001, "focus shows on the pane's edge, with no glow around it")
    }

    func test_translucentBackground_stillPaintsThePaddingRing() {
        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)

        let panel = PanelHostView(content: NSView(), meta: nil, onFocusRequest: {})
        mount(panel)

        let inRing = NSPoint(x: 5, y: panel.bounds.midY)
        XCTAssertGreaterThan(
            paintedAlpha(of: panel, at: inRing), 0,
            "the padding ring must be painted, not left showing the backdrop")

        XCTAssertEqual(
            paintedAlpha(of: panel, at: NSPoint(x: panel.bounds.midX, y: panel.bounds.midY)), 0,
            accuracy: 0.001,
            "the terminal's own area must be left unpainted for the surface to show through")
    }

    func test_translucentPanelThatFillsItsContent_paintsTheRingAndTheMiddleAlike() {
        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)

        let panel = PanelHostView(content: NSView(), meta: nil, fillsContent: true, onFocusRequest: {})
        mount(panel)

        let ring = paintedAlpha(of: panel, at: NSPoint(x: 5, y: panel.bounds.midY))
        let middle = paintedAlpha(of: panel, at: NSPoint(x: panel.bounds.midX, y: panel.bounds.midY))
        XCTAssertGreaterThan(middle, 0, "content that isn't a terminal has nothing else to paint its middle")
        XCTAssertEqual(ring, middle, accuracy: 0.02, "the padding must not read as a band around the content")
    }

    func test_dialledTranslucentAfterBuild_paintsThePaddingRing() {
        let panel = PanelHostView(content: NSView(), meta: nil, onFocusRequest: {})
        mount(panel)

        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)
        panel.reapplyTerminalBehavior()
        panel.layoutSubtreeIfNeeded()

        let inRing = NSPoint(x: 5, y: panel.bounds.midY)
        XCTAssertGreaterThan(
            paintedAlpha(of: panel, at: inRing), 0,
            "dialling the alpha down must bring the ring up on an already-built panel")
    }

    func test_drawerMeta_showsHeaderImmediately() {
        let panel = PanelHostView(
            content: NSView(),
            meta: PanelMeta(title: "Bottom drawer", action: .toggleBottomDrawer),
            onFocusRequest: {})
        mount(panel)
        XCTAssertTrue(panel.isHeaderVisibleForTesting, "a drawer's header is always shown")
    }

    func test_zoomMeta_headerHiddenUntilZoom() {
        let panel = PanelHostView(
            content: NSView(),
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
            content: NSView(),
            meta: PanelMeta(title: "Bottom drawer", action: .toggleBottomDrawer),
            zoomMeta: PanelMeta(title: "Bottom drawer: Focus Mode", action: .toggleZoom),
            onFocusRequest: {})
        mount(panel)

        XCTAssertTrue(panel.isHeaderVisibleForTesting, "a drawer's header is always shown")
        XCTAssertEqual(panel.headerContentForTesting?.title, "Bottom drawer")
        let restingShortcut = panel.headerContentForTesting?.shortcut
        XCTAssertEqual(restingShortcut, CommandCatalog.spec(for: .toggleBottomDrawer).shortcut)

        panel.isZoomed = true
        XCTAssertTrue(panel.isHeaderVisibleForTesting, "a zoomed drawer keeps its header")
        XCTAssertEqual(panel.headerContentForTesting?.title, "Bottom drawer: Focus Mode")
        XCTAssertEqual(panel.headerContentForTesting?.shortcut, CommandCatalog.spec(for: .toggleZoom).shortcut)

        panel.isZoomed = false
        XCTAssertEqual(panel.headerContentForTesting?.title, "Bottom drawer")
        XCTAssertEqual(panel.headerContentForTesting?.shortcut, restingShortcut)
    }

    func test_noMeta_neverShowsHeader() {
        let panel = PanelHostView(
            content: NSView(),
            meta: nil, onFocusRequest: {})
        mount(panel)
        XCTAssertFalse(panel.isHeaderVisibleForTesting)
        panel.isZoomed = true
        XCTAssertFalse(panel.isHeaderVisibleForTesting)
    }
}
