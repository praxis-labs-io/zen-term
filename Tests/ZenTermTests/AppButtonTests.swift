import AppKit
import XCTest

@testable import ZenTerm

final class AppButtonTests: WindowTestCase {
    private func mount(_ variant: AppButton.Variant) -> (AppButton, NSWindow) {
        let button = AppButton(title: "Add workspace", variant: variant) {}
        button.isKeyboardFocusable = true
        button.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(button)
        button.frame = NSRect(x: 0, y: 0, width: 120, height: ChromeMetrics.Height.control)
        return (button, window)
    }

    private func titleColor(_ button: AppButton) -> NSColor? {
        guard button.attributedTitle.length > 0 else { return nil }
        return button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    func test_focus_leavesAQuietPillsLabelInSubtleInk() {
        let chrome = Theme.current.chrome
        for variant in [AppButton.Variant.muted, .secondary] {
            let (button, window) = mount(variant)

            XCTAssertTrue(window.makeFirstResponder(button), "\(variant) refused focus")

            XCTAssertEqual(titleColor(button), chrome.ink(.subtle), "\(variant) shows focus with the ring alone")
            XCTAssertEqual(button.layer?.borderColor, chrome.accent.nsColor.cgColor, "\(variant) lost its ring")
        }
    }

    private func srgb(_ color: NSColor) throws -> [CGFloat] {
        let converted = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return [converted.redComponent, converted.greenComponent, converted.blueComponent]
    }

    private func distance(_ lhs: NSColor, _ rhs: NSColor) throws -> CGFloat {
        zip(try srgb(lhs), try srgb(rhs)).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
    }

    private func crossing(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    func test_aPrimaryButton_fillsWithAccent_andLabelsItAndItsGlyphInOnAccent() throws {
        let button = AppButton(title: "Connect", variant: .primary, shortcut: "⏎")
        let window = try mountFitted(button)
        let chrome = Theme.current.chrome

        XCTAssertEqual(button.layer?.backgroundColor, chrome.accent.nsColor.cgColor)
        XCTAssertEqual(titleColor(button), chrome.onAccent.nsColor)
        XCTAssertEqual(button.keycapForTesting?.inkForTesting, chrome.onAccent.nsColor)
        withExtendedLifetime(window) {}
    }

    func test_hoveringAPrimaryButton_blendsItsFillAwayFromOnAccent() throws {
        let button = AppButton(title: "Connect", variant: .primary)
        let window = try mountFitted(button)
        let chrome = Theme.current.chrome
        let accent = chrome.accent.nsColor
        let onAccent = chrome.onAccent.nsColor

        button.mouseEntered(with: try crossing(.mouseEntered, in: window))

        let hovered = try XCTUnwrap(button.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        XCTAssertNotEqual(button.layer?.backgroundColor, accent.cgColor, "hover left the fill unchanged")
        XCTAssertGreaterThan(
            try distance(hovered, onAccent), try distance(accent, onAccent), "hover narrowed the label's contrast")
        XCTAssertEqual(titleColor(button), onAccent)

        button.mouseExited(with: try crossing(.mouseExited, in: window))

        XCTAssertEqual(button.layer?.backgroundColor, accent.cgColor)
    }

    func test_focusingAPrimaryButton_ringsItInOnAccent_insetFromItsEdge() throws {
        let button = AppButton(title: "Connect", variant: .primary)
        button.isKeyboardFocusable = true
        let window = try mountFitted(button)
        let chrome = Theme.current.chrome
        let ring = button.insetRingForTesting
        XCTAssertEqual(ring.borderColor?.alpha, 0, "the ring shows at rest")

        XCTAssertTrue(window.makeFirstResponder(button))

        XCTAssertEqual(ring.borderColor, chrome.onAccent.nsColor.cgColor)
        XCTAssertEqual(ring.borderWidth, ChromeMetrics.Border.width)
        XCTAssertEqual(
            ring.frame, button.bounds.insetBy(dx: ChromeMetrics.Border.width, dy: ChromeMetrics.Border.width))
        XCTAssertEqual(button.layer?.borderColor?.alpha, 0, "an accent ring on an accent fill vanishes")
    }

    func test_aSegmentThatIsOn_labelsInNormalInk() {
        let (button, window) = mount(.segment)
        let chrome = Theme.current.chrome

        button.isOn = true

        XCTAssertEqual(titleColor(button), chrome.ink(.normal))
        XCTAssertEqual(button.layer?.backgroundColor, chrome.fill(.active).cgColor)
        withExtendedLifetime(window) {}
    }

    func test_noAppButtonLabelDrawsInAccent_exceptAFocusedLink() throws {
        let accent = Theme.current.chrome.accent.nsColor
        for variant in GalleryButtons.variants {
            for segmentOn in variant == .segment ? [false, true] : [false] {
                for state in ["rest", "hovered", "focused", "disabled"] {
                    let button = AppButton(
                        title: "Open", variant: variant, shortcut: variant == .primary ? "⏎" : nil)
                    button.isKeyboardFocusable = true
                    button.isOn = segmentOn
                    let window = try mountFitted(button)
                    switch state {
                    case "hovered": button.mouseEntered(with: try crossing(.mouseEntered, in: window))
                    case "focused": XCTAssertTrue(window.makeFirstResponder(button))
                    case "disabled": button.isEnabled = false
                    default: break
                    }
                    let name = "\(variant)\(segmentOn ? " on" : "") \(state)"
                    if variant == .link, state == "focused" {
                        XCTAssertEqual(titleColor(button), accent, "\(name) lost its accent")
                    } else {
                        XCTAssertNotEqual(titleColor(button), accent, "\(name) labels in accent")
                    }
                    XCTAssertNotEqual(button.keycapForTesting?.inkForTesting, accent, "\(name) draws an accent glyph")
                }
            }
        }
    }

    func test_focus_leavesADestructivePillsWarningTone() {
        let (button, window) = mount(.destructive)

        XCTAssertTrue(window.makeFirstResponder(button))

        XCTAssertEqual(
            titleColor(button), Theme.current.chrome.destructive.nsColor,
            "the warning tone is the message; focus must not take it")
    }

    func test_focus_stillDrawsTheAccentRing() {
        let (button, window) = mount(.muted)
        XCTAssertEqual(button.layer?.borderColor?.alpha, 0)

        XCTAssertTrue(window.makeFirstResponder(button))

        XCTAssertEqual(button.layer?.borderWidth, ChromeMetrics.Border.width)
        XCTAssertEqual(button.layer?.borderColor, Theme.current.chrome.accent.nsColor.cgColor)
    }

    func test_aSymbolOnlyButton_isSquare() throws {
        for variant: AppButton.Variant in [.primary, .secondary, .muted] {
            let button = AppButton(variant: variant, symbol: "plus")
            let window = try mountFitted(button)
            XCTAssertEqual(
                button.frame.size, NSSize(width: ChromeMetrics.Height.control, height: ChromeMetrics.Height.control),
                "\(variant)")
            withExtendedLifetime(window) {}
        }
    }

    private func mountFitted(_ button: AppButton) throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        return window
    }

    private func titleFont(_ button: AppButton) -> NSFont? {
        button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    func test_aLargeButton_keepsTheControlHeightWithALargerLabel() throws {
        let large = AppButton(title: "Connect", variant: .primary, size: .large)
        let standard = AppButton(title: "Connect", variant: .primary)
        let windows = [try mountFitted(large), try mountFitted(standard)]

        XCTAssertEqual(large.frame.height, ChromeMetrics.Height.control)
        XCTAssertEqual(titleFont(large)?.pointSize, 13)
        XCTAssertEqual(large.layer?.cornerRadius, ChromeMetrics.Radius.control)
        XCTAssertEqual(standard.frame.height, ChromeMetrics.Height.control)
        XCTAssertEqual(titleFont(standard)?.pointSize, 12)
        XCTAssertEqual(standard.layer?.cornerRadius, ChromeMetrics.Radius.control)
        withExtendedLifetime(windows) {}
    }

    func test_aClickOnAButtonsKeycap_reachesTheButton() throws {
        var taps = 0
        let button = AppButton(title: "Connect", variant: .primary, size: .large, shortcut: "⏎") { taps += 1 }
        let window = try mountFitted(button)
        let content = try XCTUnwrap(window.contentView)
        let keycap = try XCTUnwrap(button.keycapForTesting)
        let onKeycap = keycap.convert(NSPoint(x: keycap.bounds.midX, y: keycap.bounds.midY), to: content)

        let hit = content.hitTest(onKeycap)
        XCTAssertTrue(hit === button, "the keycap must not swallow the click")
        (hit as? NSButton)?.performClick(nil)

        XCTAssertEqual(taps, 1)
    }

    func test_aButtonsKeycap_sitsInsideIt_besideItsTitle() throws {
        let button = AppButton(title: "Connect", variant: .primary, shortcut: "⏎")
        let window = try mountFitted(button)
        let keycap = try XCTUnwrap(button.keycapForTesting)

        XCTAssertTrue(button.bounds.contains(keycap.frame), "the keycap is clipped by the button")
        XCTAssertEqual(button.title, "Connect")
        XCTAssertEqual(keycap.shortcut, "⏎")
        withExtendedLifetime(window) {}
    }

    func test_disablingAPrimaryButton_fadesItsKeycapGlyphWithItsLabel() throws {
        let button = AppButton(title: "Connect", variant: .primary, size: .large, shortcut: "⏎")
        let window = try mountFitted(button)
        let keycap = try XCTUnwrap(button.keycapForTesting)
        let chrome = Theme.current.chrome
        XCTAssertEqual(keycap.inkForTesting, chrome.onAccent.nsColor, "precondition: enabled reads onAccent")

        button.isEnabled = false

        XCTAssertEqual(titleColor(button), chrome.ink(.faint))
        XCTAssertEqual(keycap.inkForTesting, chrome.ink(.faint), "the glyph stayed onAccent beside a faint label")
        button.isEnabled = true
        XCTAssertEqual(keycap.inkForTesting, chrome.onAccent.nsColor)
        withExtendedLifetime(window) {}
    }

    private func lightTheme() throws -> AppTheme {
        let url = try XCTUnwrap(ThemeCatalog.bundledURL(for: "github-light-default"))
        let terminal = GhosttyThemeParser.parse(
            try String(contentsOf: url, encoding: .utf8), fontName: "Menlo", fontSize: 12,
            fallback: Theme.rosePineZen)
        return AppTheme(terminal: terminal)
    }

    private func inkiestPixel(of view: NSView, in space: NSColorSpace = .sRGB) throws -> NSColor {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var inkiest: NSColor?
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(space) else { continue }
                if pixel.alphaComponent > (inkiest?.alphaComponent ?? 0) { inkiest = pixel }
            }
        }
        return try XCTUnwrap(inkiest, "nothing was drawn")
    }

    private func disabledButtons() -> [(name: String, button: AppButton)] {
        let segmentOn = AppButton(title: "Create Worktree", variant: .segment)
        segmentOn.isOn = true
        let variants: [(String, AppButton.Variant)] = [
            ("primary", .primary), ("secondary", .secondary), ("muted", .muted),
            ("destructive", .destructive), ("segment off", .segment), ("link", .link),
        ]
        return variants.map { ($0.0, AppButton(title: "Create Worktree", variant: $0.1)) } + [("segment on", segmentOn)]
    }

    private func faintInk(over background: CGColor?, in space: NSColorSpace) throws -> NSColor {
        let ink = try XCTUnwrap(Theme.current.chrome.ink(.faint).usingColorSpace(space))
        let fill = try XCTUnwrap((background.flatMap { NSColor(cgColor: $0) } ?? .clear).usingColorSpace(space))
        let inkAlpha = ink.alphaComponent
        let fillAlpha = fill.alphaComponent * (1 - inkAlpha)
        let alpha = inkAlpha + fillAlpha
        func blend(_ i: CGFloat, _ f: CGFloat) -> CGFloat { (i * inkAlpha + f * fillAlpha) / alpha }
        let components = [
            blend(ink.redComponent, fill.redComponent), blend(ink.greenComponent, fill.greenComponent),
            blend(ink.blueComponent, fill.blueComponent), alpha,
        ]
        return NSColor(colorSpace: space, components: components, count: components.count)
    }

    private func assertDisabledLabelsDrawInFaintInk(
        theme: AppTheme, appearance: NSAppearance.Name, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let original = Theme.current
        defer { Theme.setCurrentForTesting(original) }
        Theme.setCurrentForTesting(theme)
        let space = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.extendedLinearSRGB).flatMap(NSColorSpace.init(cgColorSpace:)))

        for (name, button) in disabledButtons() {
            let window = try mountFitted(button)
            window.appearance = NSAppearance(named: appearance)
            button.isEnabled = false

            let ink = try inkiestPixel(of: button, in: space)
            let expected = try faintInk(over: button.layer?.backgroundColor, in: space)

            for (drawn, wanted) in [
                (ink.redComponent, expected.redComponent), (ink.greenComponent, expected.greenComponent),
                (ink.blueComponent, expected.blueComponent),
            ] {
                XCTAssertEqual(
                    drawn, wanted, accuracy: 0.06, "\(name) drew \(ink), wanted \(expected)", file: file, line: line)
            }
        }
    }

    func test_aDisabledButton_drawsItsLabelInTheThemesFaintInk_withALightThemeOnADarkModeMac() throws {
        try assertDisabledLabelsDrawInFaintInk(theme: try lightTheme(), appearance: .darkAqua)
    }

    func test_aDisabledButton_drawsItsLabelInTheThemesFaintInk_withADarkThemeOnALightModeMac() throws {
        try assertDisabledLabelsDrawInFaintInk(theme: Theme.builtIn, appearance: .aqua)
    }

    func test_aDisabledSegmentThatIsOn_staysSelected() throws {
        let button = AppButton(title: "main", variant: .segment)
        button.isOn = true
        let window = try mountFitted(button)
        let chrome = Theme.current.chrome

        button.isEnabled = false

        XCTAssertEqual(button.layer?.backgroundColor, chrome.fill(.active).cgColor, "the selection vanished")
        XCTAssertEqual(titleColor(button), chrome.ink(.faint))
        withExtendedLifetime(window) {}
    }

    func test_aTitleTooWideForItsButton_drawsNoInkOutsideIt() throws {
        let button = AppButton(title: "A title far too long to fit inside this button", variant: .secondary)
        button.frame = NSRect(x: 0, y: 0, width: 80, height: ChromeMetrics.Height.control)
        let cell = try XCTUnwrap(button.cell as? NSButtonCell)
        let canvas = NSRect(x: 0, y: 0, width: 400, height: ChromeMetrics.Height.control)
        let frame = button.bounds.offsetBy(dx: 160, dy: 0)
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        _ = cell.drawTitle(button.attributedTitle, withFrame: frame, in: button)
        NSGraphicsContext.restoreGraphicsState()

        let inkedColumns = (0..<rep.pixelsWide).filter { x in
            (0..<rep.pixelsHigh).contains { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 }
        }

        XCTAssertFalse(inkedColumns.isEmpty, "nothing was drawn")
        XCTAssertGreaterThanOrEqual(inkedColumns.first ?? 0, Int(frame.minX), "the title spilled left of the button")
        XCTAssertLessThanOrEqual(inkedColumns.last ?? 0, Int(frame.maxX), "the title spilled right of the button")
    }

    func test_aDisabledSymbolButton_drawsItsSymbolAtFaintInk_notDimmedFurther() throws {
        let original = Theme.current
        defer { Theme.setCurrentForTesting(original) }
        Theme.setCurrentForTesting(try lightTheme())
        let faint = Theme.current.chrome.ink(.faint)
        let button = AppButton(variant: .secondary, symbol: "plus")
        let window = try mountFitted(button)
        window.appearance = NSAppearance(named: .darkAqua)
        button.isEnabled = false

        let ink = try inkiestPixel(of: button)

        XCTAssertEqual(
            ink.alphaComponent, faint.alphaComponent, accuracy: 0.03, "the symbol was dimmed on top of faint")
    }
}
