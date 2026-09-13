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

    func test_focus_raisesTheGlow_andBlurDropsIt() {
        let panel = PanelHostView(content: NSView(), meta: nil, onFocusRequest: {})
        mount(panel)
        XCTAssertEqual(panel.haloOpacityForTesting, 0, "an unfocused panel casts no glow")

        panel.isFocused = true
        XCTAssertGreaterThan(panel.haloOpacityForTesting, 0, "focus raises the glow")

        panel.isFocused = false
        XCTAssertEqual(panel.haloOpacityForTesting, 0, "blur drops it again")
    }

    func test_focus_paintsGlowOutsideTheCard() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        host.wantsLayer = true
        let panel = PanelHostView(content: NSView(), meta: nil, onFocusRequest: {})
        panel.translatesAutoresizingMaskIntoConstraints = true
        window = NSWindow(
            contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(host)
        host.addSubview(panel)
        panel.frame = host.bounds.insetBy(dx: 40, dy: 40)
        host.layoutSubtreeIfNeeded()

        let justOutside = NSPoint(x: panel.frame.minX - 3, y: host.bounds.midY)
        XCTAssertEqual(
            paintedAlpha(of: host, at: justOutside), 0, accuracy: 0.001,
            "an unfocused panel must cast no glow")

        panel.isFocused = true
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(
            paintedAlpha(of: host, at: justOutside), 0,
            "a focused panel's glow must reach the screen, not just set an opacity")
    }

    func test_glowSitsBeneathTheCard() {
        let panel = PanelHostView(content: NSView(), meta: nil, onFocusRequest: {})
        mount(panel)
        XCTAssertTrue(
            panel.haloGeometryForTesting.isBelowCard,
            "the glow must sit under the card, not over the terminal")
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

    func test_dialledTranslucentAfterBuild_paintsThePaddingRing() {
        let panel = PanelHostView(content: NSView(), meta: nil, onFocusRequest: {})
        mount(panel)

        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)
        panel.reapplyTheme()
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
        XCTAssertEqual(panel.headerContentForTesting?.title, "BOTTOM DRAWER")
        let restingShortcut = panel.headerContentForTesting?.shortcut
        XCTAssertEqual(restingShortcut, CommandCatalog.spec(for: .toggleBottomDrawer).shortcut)

        panel.isZoomed = true
        XCTAssertTrue(panel.isHeaderVisibleForTesting, "a zoomed drawer keeps its header")
        XCTAssertEqual(panel.headerContentForTesting?.title, "BOTTOM DRAWER: FOCUS MODE")
        XCTAssertEqual(panel.headerContentForTesting?.shortcut, CommandCatalog.spec(for: .toggleZoom).shortcut)

        panel.isZoomed = false
        XCTAssertEqual(panel.headerContentForTesting?.title, "BOTTOM DRAWER")
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
