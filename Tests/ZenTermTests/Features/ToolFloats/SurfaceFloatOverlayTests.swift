import AppKit
import XCTest

@testable import ZenTerm

final class SurfaceFloatOverlayTests: WindowTestCase {
    private var originalConfig: GeneralConfig!
    private var originalTheme = Theme.builtIn
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        originalTheme = Theme.current
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDown() {
        GeneralConfig.setCurrentForTesting(originalConfig)
        Theme.setCurrentForTesting(originalTheme)
        window = nil
        super.tearDown()
    }

    private let contentInset: CGFloat = 10
    private let cornerRadius: CGFloat = 14

    @discardableResult
    private func mount(content: NSView = NSView()) -> SurfaceFloatOverlay {
        let overlay = SurfaceFloatOverlay(
            content: content, widthFraction: 0.85, heightFraction: 0.78,
            contentInset: contentInset, cornerRadius: cornerRadius, onDismiss: {})
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = window.contentView!
        host.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: host.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        return overlay
    }

    private func card(of overlay: SurfaceFloatOverlay) throws -> NSView {
        try XCTUnwrap(
            overlay.subviews.first(where: { $0 is ShadowCardView }),
            "the float must host its card in a ShadowCardView")
    }

    private func ring(of overlay: SurfaceFloatOverlay) throws -> NSView {
        try XCTUnwrap(
            try card(of: overlay).subviews.first(where: { $0 is RingFillView }),
            "the card must host a ring")
    }

    private func paintedAlpha(of view: NSView, at point: NSPoint) -> CGFloat {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.alphaComponent ?? -1
    }

    func test_cardEdge_matchesTheFocusedPaneBorder() throws {
        let card = try card(of: mount())
        XCTAssertEqual(card.layer?.borderWidth, ChromeMetrics.Border.paneFocus)
        XCTAssertEqual(card.layer?.borderColor, Theme.current.chrome.accent.nsColor.cgColor)
    }

    func test_translucentBackground_paintsTheInsetRing() throws {
        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)

        let overlay = mount()
        let ring = try ring(of: overlay)

        XCTAssertGreaterThan(
            paintedAlpha(of: ring, at: NSPoint(x: 5, y: ring.bounds.midY)), 0,
            "the inset ring must be painted, not left showing the backdrop")

        XCTAssertEqual(
            paintedAlpha(of: ring, at: NSPoint(x: ring.bounds.midX, y: ring.bounds.midY)), 0,
            accuracy: 0.001,
            "the terminal's own area must be left unpainted for the surface to show through")
    }

    func test_dialledTranslucentAfterBuild_paintsTheInsetRing() throws {
        let overlay = mount()
        let ring = try ring(of: overlay)

        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)
        overlay.reapplyTerminalBehavior()
        overlay.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            paintedAlpha(of: ring, at: NSPoint(x: 5, y: ring.bounds.midY)), 0,
            "dialling the alpha down must bring the ring up on an already-built float")
    }

    func test_solidBackground_leavesTheRingDown() throws {
        let overlay = mount()
        let card = try card(of: overlay)
        let ring = try XCTUnwrap(
            card.subviews.first(where: { $0 is RingFillView }), "the card must host a ring")

        XCTAssertTrue(ring.isHidden, "at alpha 1 the card fills the inset itself")
        XCTAssertNotNil(card.layer?.backgroundColor, "at alpha 1 the card carries its own fill")
    }

    func test_translucentBackground_bringsUpTheInWindowFrost() throws {
        let overlay = mount()
        let card = try card(of: overlay)
        let frost = try XCTUnwrap(
            card.subviews.compactMap { $0 as? NSVisualEffectView }.first,
            "the card must host a blur for its translucent state")
        XCTAssertTrue(frost.isHidden, "at alpha 1 an opaque fill covers it, so it stands down")

        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)
        overlay.reapplyTerminalBehavior()

        XCTAssertFalse(frost.isHidden, "dialling the alpha down must bring the frost up")
        XCTAssertEqual(
            frost.blendingMode, .withinWindow,
            "a behind-window blur would frost the desktop, not the panes the card covers")

        let frostIndex = try XCTUnwrap(card.subviews.firstIndex(of: frost))
        let ringIndex = try XCTUnwrap(card.subviews.firstIndex(where: { $0 is RingFillView }))
        XCTAssertLessThan(frostIndex, ringIndex, "the frost must sit under the ring, not over it")
    }

    func test_elevationShadow_darkensBelowTheCardLikeTheFloatTier_andPaintsNothingInside() throws {
        let url = try XCTUnwrap(ThemeCatalog.bundledURL(for: "nord"))
        let terminal = GhosttyThemeParser.parse(
            try String(contentsOf: url, encoding: .utf8), fontName: "Menlo", fontSize: 12,
            fallback: Theme.rosePineZen)
        Theme.setCurrentForTesting(AppTheme(terminal: terminal))
        let overlay = mount()
        let card = try card(of: overlay)
        let shadow = try XCTUnwrap(
            card.subviews.first(where: { $0 is OutsideShadowView }),
            "the card must host an outside-only shadow view")
        let floatCard = card.convert(card.bounds, to: nil)
        let floatDarkening = darkeningBelow(floatCard, in: window)

        let reference = NSView(frame: floatCard)
        reference.wantsLayer = true
        reference.layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        reference.layer?.cornerRadius = cornerRadius
        FloatShadow.apply(.float, to: reference)
        let referenceWindow = solidWindow()
        referenceWindow.contentView!.addSubview(reference)
        let referenceDarkening = darkeningBelow(floatCard, in: referenceWindow)

        XCTAssertEqual(floatDarkening.count, 2, "the float must render")
        XCTAssertEqual(referenceDarkening.count, 2, "the reference must render")
        for (float, expected) in zip(floatDarkening, referenceDarkening) {
            XCTAssertGreaterThan(expected, 2, "the reference float tier must darken the backdrop")
            XCTAssertEqual(
                float, expected, accuracy: 1,
                "the tool float must darken the backdrop as much as the float tier does")
        }

        XCTAssertEqual(
            paintedAlpha(of: shadow, at: NSPoint(x: shadow.bounds.midX, y: shadow.bounds.midY)), 0,
            accuracy: 0.001,
            "the shadow must paint nothing inside the card: that black is the interior wash")
    }

    private func solidWindow() -> NSWindow {
        let solid = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        solid.isReleasedWhenClosed = false
        return solid
    }

    private func darkeningBelow(_ card: NSRect, in window: NSWindow) -> [CGFloat] {
        let host = window.contentView!
        host.wantsLayer = true
        host.layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let width = Int(host.bounds.width)
        let height = Int(host.bounds.height)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep),
            let layer = host.layer
        else { return [] }
        context.cgContext.translateBy(x: 0, y: host.bounds.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        layer.render(in: context.cgContext)

        func luminance(at point: NSPoint) -> CGFloat {
            guard
                let color = rep.colorAt(x: Int(point.x), y: Int(host.bounds.height - point.y))?
                    .usingColorSpace(.sRGB)
            else { return -1 }
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3 * 255
        }
        let backdrop = luminance(at: NSPoint(x: 5, y: 5))
        return [4, 10].map { backdrop - luminance(at: NSPoint(x: card.midX, y: card.minY - $0)) }
    }
}
