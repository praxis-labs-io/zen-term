import AppKit
import XCTest

@testable import ZenTerm

/// The keycap's glyph rendering. The modifier glyphs are resolved once and shared by every
/// keycap on screen, since the palette used to re-resolve them per token per row per keystroke — a
/// cache that handed back nil, or one image where two were wanted, would ship blank keycaps.
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

    /// The scroll and find keys draw as glyphs no font is guaranteed to carry, so each needs a
    /// symbol name that resolves. A name that does not leaves an image view with no image, which
    /// is a keycap with a gap in it and nothing else to notice it by.
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

    /// Keys with no clean symbol stay text rather than resolving to nothing.
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

    /// The tint lives on the image view, which is what makes sharing one image safe — a keycap
    /// recolored by a theme swap must not recolor every other keycap.
    func test_reapplyTheme_recolorsWithoutDisturbingAnotherKeycap() {
        let first = KeycapView(shortcut: "⌘")
        let second = KeycapView(shortcut: "⌘")
        let secondTint = glyphs(in: second)[0].contentTintColor

        first.reapplyTheme()

        XCTAssertEqual(glyphs(in: second)[0].contentTintColor, secondTint)
        XCTAssertNotNil(glyphs(in: first)[0].image, "the rebuilt token still resolves its glyph")
    }

    /// A keycap tells you what to press, so it reads as a control at rest rather than as a caption.
    /// It carried the muted weight through the three-level migration only because its old raw alpha
    /// landed in that band, and on the narrowest-separation theme in the catalog that made the chord
    /// genuinely hard to read.
    func test_theGlyphReadsAsAControl_notACaption() {
        let keycap = KeycapView(shortcut: "⌘")
        let tint = glyphs(in: keycap)[0].contentTintColor?.usingColorSpace(.sRGB)

        XCTAssertEqual(tint?.alphaComponent, Theme.current.chrome.ink(.subtle).alphaComponent)
        XCTAssertGreaterThan(
            tint?.alphaComponent ?? 0, Theme.current.chrome.ink(.muted).alphaComponent,
            "a chord is read, not skimmed")
    }
}
