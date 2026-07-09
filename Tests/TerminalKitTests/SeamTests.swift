import AppKit
import XCTest

@testable import TerminalKit

/// A minimal in-test surface proving the protocol is coherent and usable
/// without any backend. If this compiles and routes a delegate call, the
/// seam's shape is sound.
private final class SpySurface: TerminalSurface {
    let view = NSView()
    weak var delegate: TerminalSurfaceDelegate?
    var title = "spy"
    var isFocused = false
    private(set) var started = false

    func start(_ config: TerminalSurfaceConfig) {
        started = true
        delegate?.surface(self, titleDidChange: "spy-started")
    }
    func focus() { isFocused = true }
    func terminate() {}
    func paste(_ text: String) {}
    func copySelection() -> String? { nil }
    func scrollToBottom() {}
}

private final class RecordingDelegate: TerminalSurfaceDelegate {
    var lastTitle: String?
    func surface(_ s: TerminalSurface, titleDidChange title: String) { lastTitle = title }
    // All other methods use the protocol's default no-op implementations.
}

final class SeamTests: XCTestCase {
    func test_startRoutesTitleThroughDelegate() {
        let surface = SpySurface()
        let recorder = RecordingDelegate()
        surface.delegate = recorder

        surface.start(TerminalSurfaceConfig())

        XCTAssertTrue(surface.started)
        XCTAssertEqual(recorder.lastTitle, "spy-started")
    }

    func test_configDefaults() {
        let config = TerminalSurfaceConfig()
        XCTAssertNil(config.command)
        XCTAssertTrue(config.args.isEmpty)
        XCTAssertTrue(config.environment.isEmpty)
    }

    func test_factoryDefaultsToGhosttyAndSwapsPerBackend() {
        // We construct only — starting a process is out of unit scope. The factory's
        // static backend is process-global, so restore it for other tests.
        let original = TerminalSurfaceFactory.backend
        defer { TerminalSurfaceFactory.backend = original }

        XCTAssertEqual(original, .ghostty, "libghostty is the default backend (ZEN-45)")
        XCTAssertTrue(TerminalSurfaceFactory.make() is GhosttySurface)

        TerminalSurfaceFactory.backend = .swiftTerm
        XCTAssertTrue(TerminalSurfaceFactory.make() is SwiftTermSurface)
    }
}
