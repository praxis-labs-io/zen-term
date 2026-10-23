import XCTest

@testable import ZenTerm

final class ToolFloatCatalogTests: XCTestCase {
    func test_ids_areUnique() {
        let ids = ToolFloatCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "ToolFloat ids must be unique")
    }

    func test_scratchIsTheOnlyBuiltInFloat() {
        XCTAssertEqual(ToolFloatCatalog.builtIns.map(\.id), ["scratch"])
    }

    func test_theBuiltInIsNotAConfigFloat() {
        XCTAssertTrue(GeneralConfig.builtIn.floats.isEmpty)
        XCTAssertNotNil(ToolFloatCatalog.byID("scratch"))
    }

    func test_byID_unknown_isNil() {
        XCTAssertNil(ToolFloatCatalog.byID("nope"))
    }
}
