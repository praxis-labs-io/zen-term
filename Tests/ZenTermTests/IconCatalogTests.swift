import AppKit
import XCTest

@testable import ZenTerm

/// The tool-float icon roster (ZEN-153). Two invariants that were previously only remembered: the
/// grid stays rectangular, and every symbol in it actually resolves to an image. A fat-fingered SF
/// Symbol name or a brand asset that failed to bundle renders as a blank cell in the picker with
/// nothing else to catch it.
final class IconCatalogTests: XCTestCase {
    /// `IconPickerField` lays the catalog out 8 to a row, so a count off the multiple leaves a
    /// ragged last row. Pinned here so a future edit can't quietly unbalance the grid.
    func test_all_fillsTheEightWideGridExactly() {
        XCTAssertEqual(
            IconCatalog.all.count % IconPickerField.columnsForTesting, 0,
            "\(IconCatalog.all.count) icons doesn't fill rows of \(IconPickerField.columnsForTesting)")
    }

    func test_all_hasNoDuplicates() {
        let seen = Set(IconCatalog.all)
        XCTAssertEqual(seen.count, IconCatalog.all.count, "a duplicate wastes a grid cell")
    }

    /// Catches both a mistyped SF Symbol name and a brand mark that didn't make it into the bundle
    /// — the Neovim asset replacing note.text in the curated roster.
    func test_everySymbol_resolvesToAnImage() {
        for symbol in IconCatalog.all {
            XCTAssertNotNil(IconCatalog.image(symbol), "\(symbol) resolves to nothing — blank cell")
        }
    }

    /// The brand marks resolve through `BrandMark`, not SF Symbols, and must tint like a symbol
    /// rather than render as a fixed-color bitmap.
    func test_brandMarks_loadAsTemplateImages() throws {
        for symbol in ["git", "github", "linear"] {
            XCTAssertNil(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                "\(symbol) now collides with a real SF Symbol, which would win over the brand mark")
            let image = try XCTUnwrap(IconCatalog.image(symbol), "\(symbol) failed to load")
            XCTAssertTrue(image.isTemplate, "\(symbol) must tint from the theme, not draw its own color")
        }
    }

    /// The picker labels cells with these, so a raw `dotted.symbol.name` would leak to the UI.
    func test_displayName_humanizesOrOverrides() {
        XCTAssertEqual(IconCatalog.displayName("spotify"), "Spotify")
        XCTAssertEqual(IconCatalog.displayName("note.text"), "Notes")
        XCTAssertEqual(IconCatalog.displayName("bubble.left.and.bubble.right"), "Chat")
        XCTAssertEqual(IconCatalog.displayName("envelope"), "Email", "the metaphor is mail, not the object")
        XCTAssertEqual(IconCatalog.displayName("terminal"), "Terminal", "no override → humanized")
    }

    /// A float pinned to a dropped icon keeps rendering it — `IconCatalog.image` resolves any SF
    /// Symbol whether or not it's still on the roster, so an existing user's config never breaks.
    func test_droppedIcons_stillResolve_soExistingFloatsKeepTheirGlyph() {
        for dropped in ["speedometer", "ant", "cube", "cloud", "memorychip", "note.text"] {
            XCTAssertFalse(IconCatalog.all.contains(dropped), "\(dropped) was dropped from the roster")
            XCTAssertNotNil(IconCatalog.image(dropped), "but a float still configured with it must render")
        }
    }
}
