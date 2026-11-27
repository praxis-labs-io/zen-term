import AppKit
import XCTest

@testable import ZenTerm

final class IconButtonTests: WindowTestCase {
    private final class KeyedWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private func releaseButton() -> (button: IconButton, window: NSWindow, fired: () -> Int) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        var count = 0
        let button = IconButton(symbol: "xmark", accessibilityLabel: "Close") { count += 1 }
        button.firesOnRelease = true
        window.contentView?.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(x: 10, y: 10, width: 24, height: 24)
        return (button, window, { count })
    }

    private func mouse(
        _ type: NSEvent.EventType, in window: NSWindow, at point: CGPoint, clicks: Int = 1
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }

    func test_firesOnRelease_firesOnceOnMouseUpInside_notOnPress() throws {
        let (button, window, fired) = releaseButton()
        let inside = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)

        button.mouseDown(with: try mouse(.leftMouseDown, in: window, at: inside))
        XCTAssertEqual(fired(), 0, "a press alone does not fire")
        button.mouseUp(with: try mouse(.leftMouseUp, in: window, at: inside))
        XCTAssertEqual(fired(), 1)
    }

    func test_firesOnRelease_doesNotFireWhenReleasedOutside() throws {
        let (button, window, fired) = releaseButton()
        let inside = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)

        button.mouseDown(with: try mouse(.leftMouseDown, in: window, at: inside))
        button.mouseUp(with: try mouse(.leftMouseUp, in: window, at: CGPoint(x: 90, y: 50)))
        XCTAssertEqual(fired(), 0, "a press dragged out cancels")
    }

    func test_firesOnRelease_firesOncePerDoubleClick() throws {
        let (button, window, fired) = releaseButton()
        let inside = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)

        button.mouseDown(with: try mouse(.leftMouseDown, in: window, at: inside))
        button.mouseUp(with: try mouse(.leftMouseUp, in: window, at: inside))
        button.mouseDown(with: try mouse(.leftMouseDown, in: window, at: inside, clicks: 2))
        button.mouseUp(with: try mouse(.leftMouseUp, in: window, at: inside, clicks: 2))
        XCTAssertEqual(fired(), 1)
    }

    func test_pressOnDefaultButton_stillFiresOnMouseDown() throws {
        var count = 0
        let button = IconButton(symbol: "plus", accessibilityLabel: "New tab") { count += 1 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(button)

        button.mouseDown(with: try mouse(.leftMouseDown, in: window, at: .zero))
        XCTAssertEqual(count, 1)
    }

    func test_aDisabledButton_ignoresAClickUntilItIsEnabledAgain() throws {
        var count = 0
        let button = IconButton(symbol: "chevron.up", accessibilityLabel: "Older Match") { count += 1 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(button)
        button.isEnabled = false

        button.mouseDown(with: try mouse(.leftMouseDown, in: window, at: .zero))
        XCTAssertFalse(button.accessibilityPerformPress(), "VoiceOver's press is a click too")
        XCTAssertEqual(count, 0)

        button.isEnabled = true
        button.mouseDown(with: try mouse(.leftMouseDown, in: window, at: .zero))
        XCTAssertEqual(count, 1)
    }

    func test_aDisabledReleaseButton_ignoresAFullClick() throws {
        let (button, window, fired) = releaseButton()
        let inside = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        button.isEnabled = false

        button.mouseDown(with: try mouse(.leftMouseDown, in: window, at: inside))
        button.mouseUp(with: try mouse(.leftMouseUp, in: window, at: inside))

        XCTAssertEqual(fired(), 0)
    }

    @MainActor
    func test_aDisabledButton_restsFaintAndTakesNoHoverFill() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let button = IconButton(symbol: "chevron.up", accessibilityLabel: "Older Match", onClick: {})
        window.contentView?.addSubview(button)
        button.isEnabled = false
        let hover = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                userData: nil))

        button.mouseEntered(with: hover)

        XCTAssertEqual(button.iconTintForTesting, Theme.current.chrome.ink(.faint))
        let fill = button.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
        XCTAssertEqual(fill?.alphaComponent ?? 0, 0, "a hover fill promises a click that does nothing")
    }

    func test_movedOutFromUnderAStillPointer_clearsHover() throws {
        let window = KeyedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let button = IconButton(symbol: "sidebar.left", accessibilityLabel: "Toggle sidebar", onClick: {})
        window.contentView?.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(x: 10, y: 10, width: 24, height: 24)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let hover = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                userData: nil))
        button.mouseEntered(with: hover)
        XCTAssertTrue(button.isHoveredForTesting)

        button.setFrameOrigin(NSPoint(x: 60, y: 10))
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(button.isHoveredForTesting, "a button moved from under a still pointer gets no mouseExited")
    }

    func test_hiddenWhileHovered_clearsHoverAndItsFill() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let button = IconButton(symbol: "plus", accessibilityLabel: "New tab", onClick: {})
        window.contentView?.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(x: 10, y: 10, width: 24, height: 24)
        let hover = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                userData: nil))
        button.mouseEntered(with: hover)
        XCTAssertTrue(button.isHoveredForTesting)

        button.isHidden = true
        button.isHidden = false

        XCTAssertFalse(button.isHoveredForTesting, "a hidden button gets no mouseExited, so hiding clears hover")
        let fill = button.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
        XCTAssertEqual(fill?.alphaComponent, 0, "and the fill is gone when it comes back")
    }

    func test_tooltip_labelAndLiveShortcut() {
        let withShortcut = IconButton(
            symbol: "plus", accessibilityLabel: "New tab", shortcut: { "⌘T" }, onClick: {})
        XCTAssertEqual(withShortcut.tooltipLabelForTesting, "New tab")
        XCTAssertEqual(withShortcut.tooltipShortcutForTesting, "⌘T")

        let plain = IconButton(symbol: "plus", accessibilityLabel: "New tab", onClick: {})
        XCTAssertEqual(plain.tooltipLabelForTesting, "New tab")
        XCTAssertNil(plain.tooltipShortcutForTesting, "no resolver → no shortcut in the tooltip")
    }

    func test_showsActivity_togglesTheDot() {
        let button = IconButton(
            symbol: "rectangle.bottomthird.inset.filled", accessibilityLabel: "Toggle bottom drawer",
            onClick: {})
        XCTAssertTrue(button.activityDotHiddenForTesting, "dot is hidden by default")

        button.showsActivity = true
        XCTAssertFalse(button.activityDotHiddenForTesting, "showsActivity reveals the dot")

        button.showsActivity = false
        XCTAssertTrue(button.activityDotHiddenForTesting)
    }

    @MainActor
    func test_theRestingIcon_readsStrongerThanSecondaryText() {
        let button = IconButton(symbol: "plus", accessibilityLabel: "New tab", onClick: {})
        guard let tint = button.iconTintForTesting?.usingColorSpace(.sRGB) else {
            return XCTFail("no tint painted on the glyph")
        }
        let secondary = Theme.current.chrome.ink(.muted).usingColorSpace(.sRGB)
        XCTAssertGreaterThan(
            tint.alphaComponent, secondary?.alphaComponent ?? 1,
            "the resting icon is at or below secondary-text weight")
    }

    @MainActor
    func test_theRestingIcon_staysBelowTheHoverTint() {
        XCTAssertLessThan(
            Theme.current.chrome.ink(.subtle).alphaComponent,
            Theme.current.chrome.ink(.normal).alphaComponent)
    }
}

final class IconGlyphSizeTests: XCTestCase {
    private struct Placement {
        let offset: CGFloat
        let halfPixel: CGFloat
    }

    private func inkCentreFromTop(_ rep: NSBitmapImageRep) -> CGFloat {
        var weighted: CGFloat = 0
        var total: CGFloat = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let alpha = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                weighted += (CGFloat(y) + 0.5) * alpha
                total += alpha
            }
        }
        return weighted / total * rep.size.height / CGFloat(rep.pixelsHigh)
    }

    private func glyphPlacement(_ symbol: String) throws -> Placement {
        let button = IconButton(symbol: symbol, pointSize: ChromeMetrics.Icon.sm, accessibilityLabel: symbol) {}
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        button.layoutSubtreeIfNeeded()
        let scale = button.convertToBacking(NSRect(x: 0, y: 0, width: 1, height: 1)).height
        let image = try XCTUnwrap(
            button.subviews.compactMap { $0 as? NSImageView }.first?.image, "no glyph in \(symbol)")

        let rendered = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: rendered)

        let alone = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
                pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        alone.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: alone)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        let inkInButton = inkCentreFromTop(rendered) - button.bounds.height / 2
        let inkInGlyph = inkCentreFromTop(alone) - image.size.height / 2
        return Placement(offset: inkInButton - inkInGlyph, halfPixel: 0.5 / scale)
    }

    func test_symbolsAndBrandMarks_centreWithinHalfABackingPixel() throws {
        let glyphs = ["terminal.fill", "folder.fill", "doc.text.fill", "square.stack.fill", "git", "github", "claude"]
        for glyph in glyphs {
            let placement = try glyphPlacement(glyph)
            XCTAssertLessThanOrEqual(
                abs(placement.offset), placement.halfPixel + 0.01,
                "\(glyph) sits \(placement.offset)pt off the button's centre")
        }
    }
}
