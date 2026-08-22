import CoreGraphics
import XCTest

@testable import ZenTerm

final class LayoutWriteTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zt-layout-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    func test_scalarWrite_thenReset_roundTripsThroughLoader() throws {
        let dir = try makeTempDir()
        // Write two edited knobs the way the section does.
        try ConfigWriter.apply(
            scalars: [
                "backdrop-alpha": LayoutFormat.number(0.5), "reduce-motion": "on",
            ], configRoot: dir)
        var loaded = ConfigLoader.loadGeneralConfig(configRoot: dir)
        XCTAssertEqual(loaded.backdropAlpha, 0.5, accuracy: 0.0001)
        XCTAssertEqual(loaded.reduceMotion, .on)

        // Per-row reset = removal → the key drops out, parser returns builtIn.
        try ConfigWriter.apply(removals: ["backdrop-alpha", "reduce-motion"], configRoot: dir)
        loaded = ConfigLoader.loadGeneralConfig(configRoot: dir)
        XCTAssertEqual(loaded.backdropAlpha, GeneralConfig.builtIn.backdropAlpha, accuracy: 0.0001)
        XCTAssertEqual(loaded.reduceMotion, GeneralConfig.builtIn.reduceMotion)
    }
}
