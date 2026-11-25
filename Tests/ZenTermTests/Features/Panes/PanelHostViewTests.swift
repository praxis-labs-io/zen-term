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
        let focused = PanelHostView(content: NSView(), onFocusRequest: {})
        let unfocused = PanelHostView(content: NSView(), onFocusRequest: {})
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
        let panel = PanelHostView(content: NSView(), onFocusRequest: {})
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

        let panel = PanelHostView(content: NSView(), onFocusRequest: {})
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

        let panel = PanelHostView(content: NSView(), fillsContent: true, onFocusRequest: {})
        mount(panel)

        let ring = paintedAlpha(of: panel, at: NSPoint(x: 5, y: panel.bounds.midY))
        let middle = paintedAlpha(of: panel, at: NSPoint(x: panel.bounds.midX, y: panel.bounds.midY))
        XCTAssertGreaterThan(middle, 0, "content that isn't a terminal has nothing else to paint its middle")
        XCTAssertEqual(ring, middle, accuracy: 0.02, "the padding must not read as a band around the content")
    }

    func test_dialledTranslucentAfterBuild_paintsThePaddingRing() {
        let panel = PanelHostView(content: NSView(), onFocusRequest: {})
        mount(panel)

        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)
        panel.reapplyTerminalBehavior()
        panel.layoutSubtreeIfNeeded()

        let inRing = paintedAlpha(of: panel, at: NSPoint(x: 5, y: panel.bounds.midY))
        XCTAssertGreaterThan(inRing, 0, "dialling the alpha down must bring the ring up on an already-built panel")
        XCTAssertLessThan(inRing, 0.99, "the ring still paints the opaque fill")
        XCTAssertNil(panel.paintedBackgroundForTesting.fill, "a translucent terminal panel must stop filling its clip")
    }

    private func header(_ controls: [PaneHeader.Control] = [.splitHorizontal, .splitVertical, .focusMode, .close])
        -> PaneHeader
    {
        PaneHeader(
            content: PaneHeader.Content(process: .shell, name: "zsh", detail: "~"), controls: controls,
            onControl: { _ in })
    }

    func test_aHeader_sitsAboveTheContent() throws {
        let content = NSView()
        let panel = PanelHostView(content: content, header: header(), onFocusRequest: {})
        mount(panel)

        let shown = try XCTUnwrap(panel.shownHeaderForTesting, "a pane with a header shows it at rest")
        XCTAssertGreaterThanOrEqual(
            content.frame.maxY, 0, "premise: the content is laid out")
        XCTAssertLessThanOrEqual(content.frame.maxY, shown.frame.minY, "the terminal starts below the header")
    }

    func test_paneHeadersOff_appliedLive_givesTheHeadersRoomBackToTheContent() throws {
        let content = NSView()
        let panel = PanelHostView(content: content, header: header(), onFocusRequest: {})
        mount(panel)
        let withHeader = content.frame.height

        var config = GeneralConfig.builtIn
        config.paneHeaders = false
        GeneralConfig.setCurrentForTesting(config)
        panel.reapplyChromeLayout()
        panel.layoutSubtreeIfNeeded()

        XCTAssertNil(panel.shownHeaderForTesting)
        XCTAssertGreaterThan(content.frame.height, withHeader, "the header's room goes back to the terminal")

        config.paneHeaders = true
        GeneralConfig.setCurrentForTesting(config)
        panel.reapplyChromeLayout()
        panel.layoutSubtreeIfNeeded()

        XCTAssertNotNil(panel.shownHeaderForTesting)
        XCTAssertEqual(content.frame.height, withHeader)
    }

    func test_focusMode_lightsTheHeadersFocusModeButton() throws {
        let panel = PanelHostView(content: NSView(), header: header(), onFocusRequest: {})
        mount(panel)
        let button = try XCTUnwrap(panel.header?.buttonForTesting(.focusMode))
        XCTAssertFalse(button.isActive)

        panel.isZoomed = true
        XCTAssertTrue(button.isActive, "the button stays lit while the pane is zoomed")

        panel.isZoomed = false
        XCTAssertFalse(button.isActive)
    }

    func test_beingWhereFocusSits_showsTheHeadersControls_evenWithoutTheHalo() throws {
        let panel = PanelHostView(content: NSView(), header: header(), onFocusRequest: {})
        mount(panel)
        let shown = try XCTUnwrap(panel.header)
        XCTAssertFalse(shown.controlsShownForTesting, "premise: an unfocused pane hides its controls")

        panel.isActive = true

        XCTAssertFalse(panel.isFocused, "premise: a lone pane wears no halo")
        XCTAssertTrue(shown.controlsShownForTesting)
    }

    func test_noHeader_neverShowsOne() {
        let panel = PanelHostView(content: NSView(), onFocusRequest: {})
        mount(panel)
        XCTAssertNil(panel.shownHeaderForTesting)
        panel.isZoomed = true
        XCTAssertNil(panel.shownHeaderForTesting)
    }

    func test_aRaisedVeil_leavesThePaneTakingClicks() {
        let content = NSView()
        let panel = PanelHostView(content: content, onFocusRequest: {})
        mount(panel)
        let center = NSPoint(x: 150, y: 100)

        XCTAssertTrue(panel.window?.contentView?.hitTest(center) === content, "at rest")

        panel.floatCoverDidChange(true)

        XCTAssertTrue(panel.isVeiledForTesting)
        XCTAssertTrue(
            panel.window?.contentView?.hitTest(center) === content,
            "the veil sits frontmost, so taking the hit would kill clicks, drags and scroll in every pane")
    }

    func test_aPaneAttachedWhileAFloatCoversTheWindow_comesUpVeiled() {
        let window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.floatCoversPanes = true
        let panel = PanelHostView(content: NSView(), onFocusRequest: {})

        window.contentView?.addSubview(panel)

        XCTAssertTrue(panel.isVeiledForTesting, "a split or a remounted tab under a float reads the window's state")

        window.floatCoversPanes = false

        XCTAssertFalse(panel.isVeiledForTesting)
    }
}
