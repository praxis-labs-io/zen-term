import AppKit
import XCTest

@testable import ZenTerm

/// The float/card elevation shadow must survive AppKit's view→layer re-sync. Writing
/// `layer.shadowOpacity` directly is silently zeroed when a view is nested in a subtree
/// inserted into a window (AppKit re-realizes backing layers and syncs `NSView.shadow`,
/// nil, over it) — which is exactly how every overlay presents its card. These mount into
/// a live, displayed window and assert the shadow actually survives insertion.
final class FloatShadowTests: XCTestCase {
    private var window: NSWindow!
    /// `SurfaceFloatOverlay` reads `GeneralConfig.current` at construction to pick which
    /// arrangement paints its card (ZEN-287), so without this the float below is built against the
    /// developer's own `~/.config/zen-term` — and at `background-alpha = 0` it mounts a live
    /// `NSVisualEffectView` into a displayed window, which this suite then drops. That reads as an
    /// unrelated intermittent failure in a later suite, on one machine.
    private var originalConfig: GeneralConfig!

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView!.wantsLayer = true
        window.displayIfNeeded()  // realize + display the tree, like the app's live window
    }

    override func tearDown() {
        window = nil
        GeneralConfig.setCurrentForTesting(originalConfig)
        super.tearDown()
    }

    /// opacity × color-alpha — the shadow the user actually sees.
    private func effectiveShadowAlpha(_ view: NSView) -> CGFloat {
        guard let layer = view.layer else { return 0 }
        let colorAlpha = layer.shadowColor?.alpha ?? 0
        return CGFloat(layer.shadowOpacity) * colorAlpha
    }

    func test_cardChromeShadow_survivesSubtreeInsertion() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        container.wantsLayer = true
        let card = NSView(frame: NSRect(x: 100, y: 100, width: 300, height: 200))
        CardChrome.apply(to: card, background: .black)
        container.addSubview(card)

        window.contentView!.addSubview(container)  // subtree insertion re-syncs backing layers
        window.displayIfNeeded()

        XCTAssertGreaterThan(
            effectiveShadowAlpha(card), 0.4,
            "the card chrome's elevation shadow must survive subtree insertion")
    }

    /// The float card is the one card that does NOT take a layer shadow. It hosts a terminal, so
    /// `background-alpha` can make it see-through, and a layer shadow fills `shadowPath` — which
    /// washed the interior black the moment it did (ZEN-287). It draws an outside-only shadow
    /// instead, so what has to survive presentation here is that view, not `shadowOpacity`.
    /// `SurfaceFloatOverlayTests` covers what that view paints.
    func test_surfaceFloatCard_drawsItsShadow_ratherThanCastingALayerOne() {
        let overlay = SurfaceFloatOverlay(
            content: NSView(), background: .black, widthFraction: 0.85,
            heightFraction: 0.78, contentInset: 10, cornerRadius: 14, onDismiss: {})
        let host = window.contentView!
        host.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: host.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        overlay.animateIn()
        window.displayIfNeeded()

        guard let card = overlay.subviews.first(where: { $0 is ShadowCardView }) else {
            return XCTFail("the float overlay must host its card in a ShadowCardView")
        }
        XCTAssertEqual(
            effectiveShadowAlpha(card), 0,
            "a layer shadow on the float card would fill its interior once it goes translucent")
        guard let shadow = card.subviews.first(where: { $0 is OutsideShadowView }) else {
            return XCTFail("the float card must host an OutsideShadowView")
        }
        // Inside the card, not beside it — `Motion.springScaleFade` animates the card's layer
        // alone, so a sibling would pop in flat while a sublayer springs with it.
        XCTAssertTrue(
            shadow.isDescendant(of: card), "the shadow must spring with the card, not beside it")
        XCTAssertFalse(
            card.layer?.masksToBounds ?? true, "masking the card would clip the shadow away")
    }

    func test_chromeTooltip_castsShadow_afterPresentation() {
        let tooltip = ChromeTooltip(label: "probe", shortcut: nil)
        tooltip.frame = NSRect(x: 100, y: 100, width: 120, height: 24)
        window.contentView!.addSubview(tooltip)
        window.displayIfNeeded()

        XCTAssertGreaterThan(
            effectiveShadowAlpha(tooltip), 0.3,
            "the tooltip's lighter elevation shadow must survive presentation")
    }
}
