import AppKit
import XCTest

@testable import ZenTerm

/// The keycap's glyph rendering (ZEN-15). The modifier glyphs are resolved once and shared by every
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

    /// The keys ZEN-367 bound draw as glyphs no font is guaranteed to carry, so each needs a
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

    /// The cache is keyed by symbol AND point size, so the two footprints don't share one image.
    /// Keyed by symbol alone, whichever size rendered first would be handed to every later keycap,
    /// and the diff viewer's compact legend (ZEN-262) would silently wear the palette's 10pt glyphs
    /// at 9pt metrics. Nothing about that reads as broken on screen, which is why it's asserted here.
    func test_compactAndRegular_resolveTheirOwnGlyph() throws {
        let regular = KeycapView(shortcut: "⌘", size: .regular)
        let compact = KeycapView(shortcut: "⌘", size: .compact)

        let regularImage = try XCTUnwrap(glyphs(in: regular)[0].image)
        let compactImage = try XCTUnwrap(glyphs(in: compact)[0].image)
        XCTAssertFalse(
            regularImage === compactImage,
            "a compact keycap must not be handed the regular keycap's glyph")
        XCTAssertLessThan(
            compactImage.size.height, regularImage.size.height,
            "the compact glyph renders at the smaller point size it asked for")
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
}
