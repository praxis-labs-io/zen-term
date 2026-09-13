import AppKit
import XCTest

@testable import ZenTerm

final class IconCatalogTests: XCTestCase {
    func test_symbols_fillTheEightWideGridExactly() {
        XCTAssertEqual(
            IconCatalog.symbols.count % IconPickerField.columnsForTesting, 0,
            "\(IconCatalog.symbols.count) symbols doesn't fill rows of \(IconPickerField.columnsForTesting)")
    }

    func test_brands_areTheFinalSection() {
        let titles = IconCatalog.sections(including: IconCatalog.defaultSymbol).map(\.title)
        XCTAssertEqual(titles.last, "Brand marks")
    }

    func test_all_hasNoDuplicates() {
        let seen = Set(IconCatalog.all)
        XCTAssertEqual(seen.count, IconCatalog.all.count, "a duplicate wastes a grid cell")
    }

    func test_all_isTheTwoSectionsConcatenated() {
        XCTAssertEqual(IconCatalog.all, IconCatalog.symbols + IconCatalog.brands)
    }

    func test_everySymbol_resolvesToAnImage() {
        for symbol in IconCatalog.all {
            XCTAssertNotNil(IconCatalog.image(symbol), "\(symbol) resolves to nothing — blank cell")
        }
    }

    func test_symbols_areNotFilledVariants() {
        for symbol in IconCatalog.symbols {
            XCTAssertFalse(
                symbol.contains(".fill") || symbol.contains(".filled"),
                "\(symbol) is a filled variant, which outweighs the brand marks beside it")
        }
    }

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

    func test_displayName_humanizesOrOverrides() {
        XCTAssertEqual(IconCatalog.displayName("spotify"), "Spotify")
        XCTAssertEqual(IconCatalog.displayName("play.rectangle"), "Run")
        XCTAssertEqual(IconCatalog.displayName("paperplane"), "HTTP client")
        XCTAssertEqual(IconCatalog.displayName("cpu"), "CPU")
        XCTAssertEqual(IconCatalog.displayName("openai"), "OpenAI", "humanizes to \"Openai\" on its own")
        XCTAssertEqual(IconCatalog.displayName("sqlite"), "SQLite")
        XCTAssertEqual(IconCatalog.displayName("htop"), "htop", "the tool spells its own name lowercase")
    }

    func test_displayName_dropsATrailingFillFromACustomSymbol() {
        XCTAssertEqual(IconCatalog.displayName("heart.fill"), "Heart")
        XCTAssertEqual(IconCatalog.displayName("circle.inset.filled"), "Circle inset")
        XCTAssertEqual(IconCatalog.displayName("airplane"), "Airplane", "no suffix → untouched")
        XCTAssertEqual(
            IconCatalog.displayName("externaldrive.fill.badge.plus"), "Externaldrive fill badge plus",
            "only a trailing marker goes; a mid-name .fill is part of the symbol")
    }

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

    func test_droppedIcons_keepTheirLabels() {
        XCTAssertEqual(IconCatalog.displayName("apple.terminal.on.rectangle"), "Terminal window")
        XCTAssertEqual(IconCatalog.displayName("slider.horizontal.3"), "Controls")
        XCTAssertEqual(IconCatalog.displayName("plus.forwardslash.minus"), "Diff")
        XCTAssertEqual(IconCatalog.displayName("envelope"), "Email", "the metaphor is mail, not the object")
        XCTAssertEqual(IconCatalog.displayName("note.text"), "Notes")
    }

    func test_scratchGlyph_isTheFilledFrontFaceVariant() {
        XCTAssertEqual(ToolFloat.scratch.icon, "square.fill.on.square")
        XCTAssertNotNil(IconCatalog.image(ToolFloat.scratch.icon), "the scratch float must render")
        XCTAssertEqual(IconCatalog.displayName(ToolFloat.scratch.icon), "Float")
    }

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

    func test_defaults_areOnTheRoster() {
        XCTAssertTrue(IconCatalog.all.contains(IconCatalog.defaultSymbol))
        XCTAssertTrue(IconCatalog.all.contains(ToolFloatParser.defaultIcon))
        XCTAssertEqual(IconCatalog.defaultSymbol, ToolFloatParser.defaultIcon, "one default, not two")
    }
}
