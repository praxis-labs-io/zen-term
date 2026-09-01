import AppKit
import XCTest

@testable import ZenTerm

/// The tool-float icon roster. Invariants that are otherwise only remembered: the symbols block
/// stays rectangular, every symbol resolves to an image, and a float pinned to a dropped icon keeps
/// both its glyph and its label.
final class IconCatalogTests: XCTestCase {
    /// `IconPickerField` lays each section out 8 to a row. Only the symbols block has to divide
    /// evenly — it is followed by another section, so a short row there would be a hole mid-grid.
    func test_symbols_fillTheEightWideGridExactly() {
        XCTAssertEqual(
            IconCatalog.symbols.count % IconPickerField.columnsForTesting, 0,
            "\(IconCatalog.symbols.count) symbols doesn't fill rows of \(IconPickerField.columnsForTesting)")
    }

    /// The brands block is allowed a short last row, but only because it is last: a ragged row
    /// reads as the end of the grid rather than a gap in it.
    func test_brands_areTheFinalSection() {
        let titles = IconCatalog.sections(including: IconCatalog.defaultSymbol).map(\.title)
        XCTAssertEqual(titles.last, "Brand marks")
    }

    /// 48 being a multiple of the grid width is what keeps a Down press crossing the section
    /// boundary in the same column instead of skewing.
    func test_symbolsCount_keepsVerticalNavAlignedAcrossTheBoundary() {
        XCTAssertEqual(IconCatalog.symbols.count % IconPickerField.columnsForTesting, 0)
    }

    func test_all_hasNoDuplicates() {
        let seen = Set(IconCatalog.all)
        XCTAssertEqual(seen.count, IconCatalog.all.count, "a duplicate wastes a grid cell")
    }

    func test_all_isTheTwoSectionsConcatenated() {
        XCTAssertEqual(IconCatalog.all, IconCatalog.symbols + IconCatalog.brands)
    }

    /// Catches both a mistyped SF Symbol name and a brand mark that didn't make it into the bundle.
    func test_everySymbol_resolvesToAnImage() {
        for symbol in IconCatalog.all {
            XCTAssertNotNil(IconCatalog.image(symbol), "\(symbol) resolves to nothing — blank cell")
        }
    }

    /// The roster is outline on purpose: a symbol and a mark are interchangeable choices for the
    /// same float, so they share a picker row and have to match. The marks are line art we can't
    /// restyle, so the symbols meet them — a filled roster inks roughly twice a mark.
    func test_symbols_areNotFilledVariants() {
        for symbol in IconCatalog.symbols {
            XCTAssertFalse(
                symbol.contains(".fill") || symbol.contains(".filled"),
                "\(symbol) is a filled variant, which outweighs the brand marks beside it")
        }
    }

    /// The brand marks resolve through `BrandMark`, not SF Symbols, and must tint like a symbol
    /// rather than render as a fixed-color bitmap.
    func test_brandMarks_loadAsTemplateImages() throws {
        XCTAssertFalse(IconCatalog.brands.isEmpty, "an empty roster would assert nothing below")
        for symbol in IconCatalog.brands {
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
        XCTAssertEqual(IconCatalog.displayName("play.rectangle"), "Run")
        XCTAssertEqual(IconCatalog.displayName("paperplane"), "HTTP client")
        XCTAssertEqual(IconCatalog.displayName("cpu"), "CPU")
        XCTAssertEqual(IconCatalog.displayName("openai"), "OpenAI", "humanizes to \"Openai\" on its own")
        XCTAssertEqual(IconCatalog.displayName("sqlite"), "SQLite")
        XCTAssertEqual(IconCatalog.displayName("htop"), "htop", "the tool spells its own name lowercase")
    }

    /// A user's own symbol never reaches the override table, so the fallback has to read well on
    /// its own — a trailing fill marker is a rendering variant, not part of the name.
    func test_displayName_dropsATrailingFillFromACustomSymbol() {
        XCTAssertEqual(IconCatalog.displayName("heart.fill"), "Heart")
        XCTAssertEqual(IconCatalog.displayName("circle.inset.filled"), "Circle inset")
        XCTAssertEqual(IconCatalog.displayName("airplane"), "Airplane", "no suffix → untouched")
        XCTAssertEqual(
            IconCatalog.displayName("externaldrive.fill.badge.plus"), "Externaldrive fill badge plus",
            "only a trailing marker goes; a mid-name .fill is part of the symbol")
    }

    /// A float pinned to a dropped icon keeps rendering it — `IconCatalog.image` resolves any SF
    /// Symbol whether or not it's still on the roster, so an existing user's config never breaks.
    /// `htop` is why a dropped brand mark stays bundled: nothing else would resolve it.
    func test_droppedIcons_stillResolve_soExistingFloatsKeepTheirGlyph() {
        let dropped = [
            "chevron.left.forwardslash.chevron.right", "curlybraces", "wrench.and.screwdriver",
            "gauge", "chart.line.uptrend.xyaxis", "server.rack", "network",
            "filemenu.and.selection", "checklist", "arrow.triangle.branch", "arrow.triangle.pull",
            "plus.forwardslash.minus", "apple.terminal.on.rectangle", "note.text",
            "slider.horizontal.3", "htop",
        ]
        for symbol in dropped {
            XCTAssertFalse(IconCatalog.all.contains(symbol), "\(symbol) was dropped from the roster")
            XCTAssertNotNil(IconCatalog.image(symbol), "but a float still configured with it must render")
        }
    }

    /// Their labels are the reason the overrides for dropped symbols stay in the table.
    func test_droppedIcons_keepTheirLabels() {
        XCTAssertEqual(IconCatalog.displayName("apple.terminal.on.rectangle"), "Terminal window")
        XCTAssertEqual(IconCatalog.displayName("slider.horizontal.3"), "Controls")
        XCTAssertEqual(IconCatalog.displayName("plus.forwardslash.minus"), "Diff")
        XCTAssertEqual(IconCatalog.displayName("envelope"), "Email", "the metaphor is mail, not the object")
        XCTAssertEqual(IconCatalog.displayName("note.text"), "Notes")
    }

    /// Scratch is the app's own float, so its glyph follows the chrome pattern the drawer
    /// buttons use — an outline container with one solid filled region, not a wash.
    func test_scratchGlyph_isTheFilledFrontFaceVariant() {
        XCTAssertEqual(ToolFloat.scratch.icon, "square.fill.on.square")
        XCTAssertNotNil(IconCatalog.image(ToolFloat.scratch.icon), "the scratch float must render")
        XCTAssertEqual(IconCatalog.displayName(ToolFloat.scratch.icon), "Float")
    }

    /// Editing a float pinned off the roster must not silently drop its glyph — it gets its own
    /// leading section instead.
    func test_sections_leadWithACustomSymbol() {
        let sections = IconCatalog.sections(including: "heart.fill")
        XCTAssertEqual(sections.first?.title, "Current")
        XCTAssertEqual(sections.first?.symbols, ["heart.fill"])
        XCTAssertEqual(sections.count, 3)
    }

    func test_sections_omitTheCustomBlockForARosterSymbol() {
        let sections = IconCatalog.sections(including: "terminal")
        XCTAssertEqual(sections.map(\.title), ["Symbols", "Brand marks"])
    }

    /// The parser default has to be a cell the picker actually shows, or a brand-new float opens
    /// the grid with nothing highlighted.
    func test_defaults_areOnTheRoster() {
        XCTAssertTrue(IconCatalog.all.contains(IconCatalog.defaultSymbol))
        XCTAssertTrue(IconCatalog.all.contains(ToolFloatParser.defaultIcon))
        XCTAssertEqual(IconCatalog.defaultSymbol, ToolFloatParser.defaultIcon, "one default, not two")
    }
}
