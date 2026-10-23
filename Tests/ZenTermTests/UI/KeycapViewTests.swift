import AppKit
import XCTest

@testable import ZenTerm

final class KeycapViewTests: XCTestCase {
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func glyphs(in keycap: KeycapView) -> [NSImageView] {
        descendants(of: keycap).compactMap { $0 as? NSImageView }
    }

    func test_shortcut_rendersAGlyphPerModifierAndTextForTheKey() {
        let keycap = KeycapView(shortcut: "⌘⇧P")

        let images = glyphs(in: keycap)
        XCTAssertEqual(images.count, 2, "⌘ and ⇧ each render as a symbol")
        XCTAssertTrue(images.allSatisfy { $0.image != nil }, "a keycap with no image is a blank box")
        XCTAssertEqual(
            descendants(of: keycap).compactMap { ($0 as? NSTextField)?.stringValue }, ["P"],
            "the key itself stays text")
    }

    func test_theKeysThatTypeNothing_renderAsSymbols() {
        for shortcut in ["⌘↖", "⌘↘", "⌘⇞", "⌘⇟"] {
            let keycap = KeycapView(shortcut: shortcut)
            let images = glyphs(in: keycap)
            XCTAssertEqual(images.count, 2, shortcut)
            XCTAssertTrue(images.allSatisfy { $0.image != nil }, "\(shortcut) has a blank token")
            XCTAssertEqual(
                descendants(of: keycap).compactMap { ($0 as? NSTextField)?.stringValue }, [],
                "\(shortcut) fell back to text, which is the tofu this avoids")
        }
    }

    func test_punctuationKey_staysText() {
        let keycap = KeycapView(shortcut: "⌘[")

        XCTAssertEqual(glyphs(in: keycap).count, 1)
        XCTAssertEqual(descendants(of: keycap).compactMap { ($0 as? NSTextField)?.stringValue }, ["["])
    }

    func test_twoKeycaps_shareTheSameResolvedGlyph() {
        let first = KeycapView(shortcut: "⌘")
        let second = KeycapView(shortcut: "⌘")

        XCTAssertTrue(
            glyphs(in: first)[0].image === glyphs(in: second)[0].image,
            "the glyph resolves once and is shared, not re-resolved per keycap")
    }

    func test_reapplyTheme_recolorsWithoutDisturbingAnotherKeycap() {
        let first = KeycapView(shortcut: "⌘")
        let second = KeycapView(shortcut: "⌘")
        let secondTint = glyphs(in: second)[0].contentTintColor

        first.reapplyTheme()

        XCTAssertEqual(glyphs(in: second)[0].contentTintColor, secondTint)
        XCTAssertNotNil(glyphs(in: first)[0].image, "the rebuilt token still resolves its glyph")
    }

    func test_theGlyphReadsAsAControl_notACaption() {
        let keycap = KeycapView(shortcut: "⌘")
        let tint = glyphs(in: keycap)[0].contentTintColor?.usingColorSpace(.sRGB)

        XCTAssertEqual(tint?.alphaComponent, Theme.current.chrome.ink(.subtle).alphaComponent)
        XCTAssertGreaterThan(
            tint?.alphaComponent ?? 0, Theme.current.chrome.ink(.muted).alphaComponent,
            "a chord is read, not skimmed")
    }
}
