import XCTest

@testable import ZenTerm

final class ToolFloatCatalogTests: XCTestCase {
    func test_ids_areUnique() {
        let ids = ToolFloatCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "ToolFloat ids must be unique")
    }

    func test_scratchIsTheOnlyBuiltInFloat() {
        // gitdash was dropped as a built-in; Scratch is the one that came back, and the only one.
        XCTAssertEqual(ToolFloatCatalog.builtIns.map(\.id), ["scratch"])
    }

    func test_theBuiltInIsNotAConfigFloat() {
        // It lives in the catalog, not in the config, so a fresh install still writes nothing.
        XCTAssertTrue(GeneralConfig.builtIn.floats.isEmpty)
        XCTAssertNotNil(ToolFloatCatalog.byID("scratch"))
    }

    func test_byID_unknown_isNil() {
        XCTAssertNil(ToolFloatCatalog.byID("nope"))
    }
}
