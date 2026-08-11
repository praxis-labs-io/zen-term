import AppKit
import XCTest

@testable import ZenTerm

/// `background-alpha` governs a tool float the way it already governs a pane. The two
/// things worth pixels here are the two that are invisible to any assertion on a color or a hidden
/// flag: whether the inset ring paints at all, and whether the elevation shadow stays outside the
/// card. Everything else about the float — where it sits, how the shadow reads, the ring's shade
/// beside a pane — is a look and belongs in the handover runbook.
final class SurfaceFloatOverlayTests: WindowTestCase {
    /// `SurfaceFloatOverlay` reads `GeneralConfig.current` to decide which arrangement paints the
    /// card, so every test here would otherwise build against the developer's own
    /// `~/.config/zen-term`. Saved and restored rather than reset, so a sibling suite's pin
    /// survives this one.
    private var originalConfig: GeneralConfig!
    /// Retained so a mounted overlay stays in a window for the length of a test.
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDown() {
        GeneralConfig.setCurrentForTesting(originalConfig)
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

    /// The ring is sampled on its own rather than through the card, because the frost beneath it
    /// legitimately covers the terminal's area — so a card-wide read can't tell "the ring left its
    /// hole" from "the ring painted straight through".
    private func ring(of overlay: SurfaceFloatOverlay) throws -> NSView {
        try XCTUnwrap(
            try card(of: overlay).subviews.first(where: { $0 is RingFillView }),
            "the card must host a ring")
    }

    /// Renders `view` and returns the alpha actually painted at a point, 0…1.
    private func paintedAlpha(of view: NSView, at point: NSPoint) -> CGFloat {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        // `colorAt` indexes PIXELS and the rep is backing-scaled, so a point read straight through
        // lands somewhere else entirely on a Retina backing.
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.alphaComponent ?? -1
    }

    /// Below full opacity the card stops filling its own interior and the ring takes over the
    /// inset alone. If it doesn't paint, the band between the border and the terminal shows raw
    /// backdrop and reads a shade off from the terminal beside it.
    func test_translucentBackground_paintsTheInsetRing() throws {
        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)

        let overlay = mount()
        let ring = try ring(of: overlay)

        // 5pt in from the card's left edge, vertically centred: inside the 10pt inset, outside
        // the terminal.
        XCTAssertGreaterThan(
            paintedAlpha(of: ring, at: NSPoint(x: 5, y: ring.bounds.midY)), 0,
            "the inset ring must be painted, not left showing the backdrop")

        // The centre has to stay clear, or the fill is painting straight through the terminal —
        // which is what a stale (or zero) hole does, and looks identical to a correct ring from
        // the inset alone.
        XCTAssertEqual(
            paintedAlpha(of: ring, at: NSPoint(x: ring.bounds.midX, y: ring.bounds.midY)), 0,
            accuracy: 0.001,
            "the terminal's own area must be left unpainted for the surface to show through")
    }

    /// The live path: a float built solid, then dialled translucent from Settings. The ring stands
    /// down while solid, so this is the transition that has to un-hide and paint it.
    func test_dialledTranslucentAfterBuild_paintsTheInsetRing() throws {
        // setUp pinned .builtIn: alpha 1, so the card fills and the ring stands down.
        let overlay = mount()
        let ring = try ring(of: overlay)

        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)
        overlay.reapplyTheme()
        overlay.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            paintedAlpha(of: ring, at: NSPoint(x: 5, y: ring.bounds.midY)), 0,
            "dialling the alpha down must bring the ring up on an already-built float")
    }

    /// At full opacity nothing changed: the card fills edge to edge and the ring stays down. A
    /// ring that painted anyway would double up over the fill and darken the inset.
    func test_solidBackground_leavesTheRingDown() throws {
        let overlay = mount()
        let card = try card(of: overlay)
        let ring = try XCTUnwrap(
            card.subviews.first(where: { $0 is RingFillView }), "the card must host a ring")

        XCTAssertTrue(ring.isHidden, "at alpha 1 the card fills the inset itself")
        XCTAssertNotNil(card.layer?.backgroundColor, "at alpha 1 the card carries its own fill")
    }

    /// A translucent pane reveals the window's `.behindWindow` blur; a float has opaque panes
    /// behind it, so it carries its own in-window frost or the card reads as a hole onto the
    /// terminal underneath. Structural, not a look: a frost that never mounts, never un-hides, or
    /// blends the wrong way is invisible to every other assertion here and shows up only on screen.
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
        overlay.reapplyTheme()

        XCTAssertFalse(frost.isHidden, "dialling the alpha down must bring the frost up")
        XCTAssertEqual(
            frost.blendingMode, .withinWindow,
            "a behind-window blur would frost the desktop, not the panes the card covers")

        // Below the ring and the terminal, or it frosts the float's own content.
        let frostIndex = try XCTUnwrap(card.subviews.firstIndex(of: frost))
        let ringIndex = try XCTUnwrap(card.subviews.firstIndex(where: { $0 is RingFillView }))
        XCTAssertLessThan(frostIndex, ringIndex, "the frost must sit under the ring, not over it")
    }

    /// The defect this exists to fix, and the one that a look can miss until the card goes
    /// translucent: Core Animation renders a layer shadow by *filling* `shadowPath`, so the float's
    /// black washed its whole interior. Drawn as an outside-only shadow, it must reach past the
    /// card and paint nothing at all where the card sits.
    func test_elevationShadow_reachesOutsideTheCard_andPaintsNothingInside() throws {
        let overlay = mount()
        let card = try card(of: overlay)
        let shadow = try XCTUnwrap(
            card.subviews.first(where: { $0 is OutsideShadowView }),
            "the card must host an outside-only shadow view")

        // The card's bottom edge, in the shadow view's own (outset) coordinates. The offset casts
        // downward, so a few points below it is where the shadow is densest.
        let cardBottom = shadow.convert(NSPoint(x: card.bounds.midX, y: 0), from: card)
        XCTAssertGreaterThan(
            paintedAlpha(of: shadow, at: NSPoint(x: cardBottom.x, y: cardBottom.y - 4)), 0,
            "the elevation shadow must actually reach the screen outside the card")

        XCTAssertEqual(
            paintedAlpha(of: shadow, at: NSPoint(x: shadow.bounds.midX, y: shadow.bounds.midY)), 0,
            accuracy: 0.001,
            "the shadow must paint nothing inside the card — that black is the interior wash")
    }
}
