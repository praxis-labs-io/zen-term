import XCTest

@testable import TerminalKit

final class BundleZenResourceTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    private func makeRoot(containing bundleName: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenres-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        if let bundleName {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("\(bundleName).bundle"),
                withIntermediateDirectories: true)
        }
        return root
    }

    private var sentinel: Bundle { Bundle(for: Self.self) }

    func test_resolvesBundleFromMatchingRoot_notFallback() throws {
        let root = try makeRoot(containing: "Widget")
        let resolved = Bundle.zenResourceBundle(
            named: "Widget", searchRoots: [root], fallback: sentinel)
        XCTAssertEqual(
            resolved.bundleURL.standardizedFileURL,
            root.appendingPathComponent("Widget.bundle").standardizedFileURL,
            "must resolve the real bundle, not fall through to Bundle.module")
    }

    func test_firstMatchingRootWins() throws {
        let miss = try makeRoot()
        let first = try makeRoot(containing: "Widget")
        let second = try makeRoot(containing: "Widget")
        let resolved = Bundle.zenResourceBundle(
            named: "Widget", searchRoots: [miss, first, second], fallback: sentinel)
        XCTAssertEqual(
            resolved.bundleURL.standardizedFileURL,
            first.appendingPathComponent("Widget.bundle").standardizedFileURL)
    }

    func test_fallsBackWhenNoRootHasBundle() throws {
        let root = try makeRoot(containing: "Something-Else")
        let resolved = Bundle.zenResourceBundle(
            named: "Widget", searchRoots: [root, nil], fallback: sentinel)
        XCTAssertEqual(resolved.bundleURL, sentinel.bundleURL, "must return the fallback bundle")
    }

    func test_bundleName_matchesEmittedBundle() {
        XCTAssertEqual(
            "\(TerminalKitResources.bundleName).bundle",
            Bundle.module.bundleURL.lastPathComponent)
    }

    func test_passthroughShaderIsBundled() throws {
        let path = try XCTUnwrap(
            TerminalKitResources.passthroughShaderPath, "passthrough.glsl missing from the bundle")
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(source.contains("void mainImage"), "must be a loadable shader")
    }
}
