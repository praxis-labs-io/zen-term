import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

private func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

final class IconBadgeTests: XCTestCase {
    private var originalTheme: AppTheme!

    override func setUp() {
        super.setUp()
        GeneralConfig.setCurrentForTesting(.builtIn)
        originalTheme = Theme.current
    }

    override func tearDown() {
        Theme.setCurrentForTesting(originalTheme)
        super.tearDown()
    }

    private func lightTheme() throws -> AppTheme {
        var terminal = Theme.zenInk
        terminal.background = try XCTUnwrap(TerminalColor(hex: "#faf4ed"))
        terminal.foreground = try XCTUnwrap(TerminalColor(hex: "#575279"))
        return AppTheme(terminal: terminal)
    }

    private func claude() -> ProcessIcon { ProcessIcon.forAgent("claude") }

    func test_aProcessChip_isAnAppIcon_continuousCornersAtItsSize_aThemeEdgeAndASheen() {
        let chip = IconBadge(process: claude(), size: .small)
        chip.layoutSubtreeIfNeeded()

        XCTAssertEqual(chip.fittingSize, NSSize(width: 16, height: 16))
        XCTAssertEqual(chip.layer?.cornerRadius, ChromeMetrics.Radius.icon(16))
        XCTAssertEqual(chip.layer?.cornerCurve, .continuous)
        XCTAssertEqual(chip.layer?.borderWidth, ChromeMetrics.Border.width)
        XCTAssertEqual(chip.edgeForTesting, Theme.current.chrome.fill(alpha: ChromeTheme.border).cgColor)
        XCTAssertTrue(chip.hasSheenForTesting)
        XCTAssertTrue(chip.sheenLitFromTopForTesting, "a layer's y runs up, so the light starts at y = 1")
        XCTAssertEqual(
            chip.iconFrameForTesting.width, ChromeMetrics.Icon.sm * claude().scale, accuracy: 1,
            "a 1x display snaps the box to whole points")
        XCTAssertLessThan(
            claude().scale, ProcessIcon.shell.scale, "a brand mark sits inside the box a Lucide glyph fills")
    }

    func test_aWorkspaceChip_followsALiveAccentChange_andDrawsNeutralOnAWhiteAccent() {
        let terminal = Theme.current.terminal
        let chip = IconBadge(process: .workspace, size: .small)

        Theme.setCurrentForTesting(AppTheme(terminal: terminal, accent: .green))
        chip.reapplyTheme()
        XCTAssertEqual(chip.iconTintForTesting, AccentSlot.green.color(in: terminal).nsColor)

        Theme.setCurrentForTesting(AppTheme(terminal: terminal, accent: .white))
        chip.reapplyTheme()
        XCTAssertEqual(chip.iconTintForTesting, Theme.current.chrome.ink(.normal))
        XCTAssertEqual(chip.fillForTesting, Theme.current.chrome.chipRaised.nsColor.cgColor)
    }

    func test_aClosedWorkspaceChip_isNeutral_withItsGlyphAtMutedInk() {
        let chip = IconBadge(process: .closedWorkspace, size: .small)

        XCTAssertEqual(chip.iconTintForTesting, Theme.current.chrome.ink(.muted))
        XCTAssertEqual(chip.fillForTesting, Theme.current.chrome.chipRaised.nsColor.cgColor)
    }

    func test_aBrandChip_keepsItsBrandsColorsOnEveryTheme_whileItsEdgeFollowsTheTheme() throws {
        let chip = IconBadge(process: claude(), size: .regular)
        let darkFill = chip.fillForTesting
        let darkEdge = chip.edgeForTesting

        Theme.setCurrentForTesting(try lightTheme())
        chip.reapplyTheme()

        XCTAssertEqual(chip.fillForTesting, darkFill, "the clay belongs to Claude, not the theme")
        XCTAssertEqual(chip.fillForTesting, TerminalColor(red: 0xD9, green: 0x77, blue: 0x57).nsColor.cgColor)
        XCTAssertEqual(chip.iconTintForTesting, TerminalColor(red: 0xFF, green: 0xFF, blue: 0xFF).nsColor)
        XCTAssertNotEqual(chip.edgeForTesting, darkEdge, "the edge is what holds the chip apart from this theme")
    }

    func test_aNeutralChip_takesTheChipsRaisedFillAndInk_onDarkAndLightThemes() throws {
        let chip = IconBadge(process: .shell, size: .small)
        for theme in [Theme.current, try lightTheme()] {
            Theme.setCurrentForTesting(theme)
            chip.reapplyTheme()
            let chrome = Theme.current.chrome
            XCTAssertEqual(chip.fillForTesting, chrome.chipRaised.nsColor.cgColor)
            XCTAssertEqual(chip.iconTintForTesting, chrome.ink(.normal))
            XCTAssertEqual(chip.edgeForTesting, chrome.fill(alpha: ChromeTheme.border).cgColor)
        }
    }

    func test_anArtworkChip_drawsItsMarksOwnColors() throws {
        let chip = IconBadge(process: ProcessIcon.forAgent("gemini"), size: .small)

        XCTAssertNil(chip.iconTintForTesting, "a tint would flatten Gemini's gradient")
        XCTAssertFalse(try XCTUnwrap(chip.iconImageForTesting).isTemplate)
    }

    func test_showingAnotherProcess_swapsTheMarkFillAndGlyphBox() {
        let chip = IconBadge(process: .shell, size: .regular)
        let go = ProcessIcon.forProgram("go")

        chip.show(go)
        chip.layoutSubtreeIfNeeded()

        XCTAssertEqual(chip.process, go)
        XCTAssertEqual(chip.fillForTesting, TerminalColor(red: 0x00, green: 0xAD, blue: 0xD8).nsColor.cgColor)
        XCTAssertEqual(
            chip.iconFrameForTesting.width, 16 * go.scale, accuracy: 0.01, "Go's wide mark takes a larger box")
    }

    func test_aToastsGlyph_isABareSymbolInItsRole_notAChip() {
        let toast = ToastView(content: ToastContent(variant: .warning, title: "Title", message: "Message"))

        XCTAssertFalse(descendants(of: toast).contains { $0 is IconBadge }, "the toast still mounts a badge chip")
        XCTAssertEqual(toast.glyphTintForTesting, ToastVariant.warning.role(in: Theme.current.chrome).nsColor)
    }

    func test_anUpdateCardsBadge_isTheBrandMarkOnAnAccentChip() throws {
        let card = UpdateCardView(
            state: .available(version: "9.9.9", current: "You're on 1.0", notes: [], notesURL: nil),
            actions: .init())
        let chrome = Theme.current.chrome
        let badge = card.badgeForTesting
        badge.layoutSubtreeIfNeeded()

        XCTAssertEqual(badge.fittingSize, NSSize(width: 28, height: 28))
        XCTAssertEqual(badge.layer?.cornerRadius, ChromeMetrics.Radius.control)
        XCTAssertEqual(card.badgeFillForTesting, chrome.tint(chrome.accent, alpha: ChromeTheme.badgeTint).cgColor)
        XCTAssertEqual(card.badgeIconTintForTesting, chrome.accent.nsColor)
        XCTAssertNotNil(badge.iconImageForTesting)
        XCTAssertEqual(badge.iconFrameForTesting.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(badge.iconFrameForTesting.midX, 14, accuracy: 0.5)
        XCTAssertEqual(badge.iconFrameForTesting.midY, 14, accuracy: 0.5)
    }
}
