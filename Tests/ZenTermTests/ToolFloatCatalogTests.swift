import XCTest

@testable import ZenTerm

final class ToolFloatCatalogTests: XCTestCase {
    func test_ids_areUnique() {
        let ids = ToolFloatCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "ToolFloat ids must be unique")
    }

    func test_noBuiltInFloats() {
        // Floats are entirely config-driven; with no config there are none (gitdash was
        // dropped as a built-in — it lives in the user's personal config now).
        XCTAssertTrue(GeneralConfig.builtIn.floats.isEmpty)
    }

    func test_byID_unknown_isNil() {
        XCTAssertNil(ToolFloatCatalog.byID("nope"))
    }
}
