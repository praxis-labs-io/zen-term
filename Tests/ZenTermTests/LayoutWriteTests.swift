import CoreGraphics
import XCTest

@testable import ZenTerm

final class LayoutWriteTests: XCTestCase {
    func test_scalarWrite_thenReset_roundTripsThroughLoader() throws {
        let dir = try makeTempDir()
        try ConfigWriter.apply(
            scalars: [
                "backdrop-alpha": LayoutFormat.number(0.5), "reduce-motion": "on",
            ], configRoot: dir)
        var loaded = ConfigLoader.loadGeneralConfig(configRoot: dir)
        XCTAssertEqual(loaded.backdropAlpha, 0.5, accuracy: 0.0001)
        XCTAssertEqual(loaded.reduceMotion, .on)

        try ConfigWriter.apply(removals: ["backdrop-alpha", "reduce-motion"], configRoot: dir)
        loaded = ConfigLoader.loadGeneralConfig(configRoot: dir)
        XCTAssertEqual(loaded.backdropAlpha, GeneralConfig.builtIn.backdropAlpha, accuracy: 0.0001)
        XCTAssertEqual(loaded.reduceMotion, GeneralConfig.builtIn.reduceMotion)
    }
}
