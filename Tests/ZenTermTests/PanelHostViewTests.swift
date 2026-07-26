import AppKit
import XCTest

@testable import ZenTerm

/// ZEN-65 replaced the floating corner icons with a real header: a drawer shows its title +
/// keybind always (swapping to a "<drawer>: Focus Mode" ⌘F variant while zoomed); a pane shows a
/// "Terminal pane: Focus Mode" header only while zoomed. Per the house rule "GUI controls need
/// interaction tests", these mount the panel and drive its zoom state.
final class PanelHostViewTests: XCTestCase {
    /// `PanelHostView` reads `GeneralConfig.current` at construction to decide which arrangement
    /// paints the panel, so every test here would otherwise build against the developer's own
    /// `~/.config/zen-term`. Saved and restored rather than reset, so a sibling suite's pin
    /// survives this one.
    private var originalConfig: GeneralConfig!
    /// Retained so a mounted panel stays in a window for the length of a test.
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

    /// Renders the panel and returns the alpha actually painted at a point, 0…1. The ring is the
    /// one thing here worth sampling pixels for: whether it painted at all is invisible to any
    /// assertion on its color or hidden flag, and an unpainted ring reads as a see-through band
    /// between the border and the terminal.
    private func paintedAlpha(of view: NSView, at point: NSPoint) -> CGFloat {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        // `colorAt` indexes PIXELS and the rep is backing-scaled, so a point read straight through
        // lands somewhere else entirely on a Retina backing.
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.alphaComponent ?? -1
    }

    /// ZEN-282 moved the focus glow off the card's own `shadowOpacity` and onto a sibling view,
    /// because Core Animation fills `shadowPath` and so painted the accent across the pane
    /// interior once `background-alpha` made it see-through.
    func test_focus_raisesTheGlow_andBlurDropsIt() {
        let panel = PanelHostView(content: NSView(), meta: nil, onFocusRequest: {})
        mount(panel)
        XCTAssertEqual(panel.haloOpacityForTesting, 0, "an unfocused panel casts no glow")

        panel.isFocused = true
        XCTAssertGreaterThan(panel.haloOpacityForTesting, 0, "focus raises the glow")

        panel.isFocused = false
        XCTAssertEqual(panel.haloOpacityForTesting, 0, "blur drops it again")
    }

    /// The glow has to reach the screen at all. Asserting its opacity and z-order does not
    /// establish that — both were green while it rendered a glow measured at 0.035 alpha, which
    /// reads as nothing, because a CGContext shadow is far weaker than the layer shadow it
    /// replaced and the opacity multiplier on top compounded it.
    ///
    /// Note what this does and does not catch: it fails on a glow that paints *nothing* (a clip
    /// that removes everything, a draw that no-ops, a hidden or mis-stacked view), not on one
    /// that is merely too faint to see. Where the line between those sits is a look, and stays
    /// in the handover runbook (ZEN-282).
    func test_focus_paintsGlowOutsideTheCard() {
        // Mount inset inside a larger host, because the glow lands outside the panel's own bounds.
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

        // 3pt outside the panel's left edge: inside the glow's reach, outside the card.
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

    /// Z-order is the part a focus assertion can't see: the glow renders *under* the card, and a
    /// view tree that mounts it over the terminal looks identical to one that doesn't. How far it
    /// reaches past the panel is a look, so that goes in the handover runbook, not here.
    func test_glowSitsBeneathTheCard() {
        let panel = PanelHostView(content: NSView(), meta: nil, onFocusRequest: {})
        mount(panel)
        XCTAssertTrue(
            panel.haloGeometryForTesting.isBelowCard,
            "the glow must sit under the card, not over the terminal")
    }

    /// Below full opacity the clip stops filling the panel and the ring takes over the padding
    /// alone. If it doesn't paint, the inset between the border and the terminal shows raw
    /// backdrop and reads a shade off from the terminal beside it (ZEN-282).
    func test_translucentBackground_stillPaintsThePaddingRing() {
        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)

        let panel = PanelHostView(content: NSView(), meta: nil, onFocusRequest: {})
        mount(panel)

        // 5pt in from the left edge, vertically centred: inside the 10pt padding, outside the
        // terminal content.
        let inRing = NSPoint(x: 5, y: panel.bounds.midY)
        XCTAssertGreaterThan(
            paintedAlpha(of: panel, at: inRing), 0,
            "the padding ring must be painted, not left showing the backdrop")

        // The centre has to stay clear, or the fill is painting straight through the terminal —
        // which is what a stale (or zero) hole does, and it looks identical to a correct ring
        // from the padding alone.
        XCTAssertEqual(
            paintedAlpha(of: panel, at: NSPoint(x: panel.bounds.midX, y: panel.bounds.midY)), 0,
            accuracy: 0.001,
            "the terminal's own area must be left unpainted for the surface to show through")
    }

    /// The live path: a panel built solid, then dialled translucent from Settings. The ring is
    /// hidden while solid, so this is the transition that has to un-hide and paint it.
    func test_dialledTranslucentAfterBuild_paintsThePaddingRing() {
        // setUp pinned .builtIn: alpha 1, so the ring stands down and the clip fills.
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
            content: NSView(),
            meta: nil, onFocusRequest: {})
        mount(panel)
        XCTAssertFalse(panel.isHeaderVisibleForTesting)
        panel.isZoomed = true  // no zoomMeta supplied → still nothing to show
        XCTAssertFalse(panel.isHeaderVisibleForTesting)
    }
}
