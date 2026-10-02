import AppKit
import XCTest

@testable import TerminalKit

final class DetachedSurfaceSizeTests: XCTestCase {
    private let frame = NSRect(x: 0, y: 0, width: 780, height: 560)
    // A login shell's startup, which the grid has always had to beat: libghostty has no size to start at.
    private static let shellStartup = 0.5
    private var window: NSWindow!
    private var surfaces: [GhosttySurface] = []
    private var outputs: [URL] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
    }

    override func tearDown() {
        for surface in surfaces {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        surfaces = []
        outputs.forEach { try? FileManager.default.removeItem(at: $0) }
        window.close()
        window = nil
        super.tearDown()
    }

    private func reportingSize(backingScale: CGFloat?) throws -> (GhosttySurface, URL) {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("zt-size-\(UUID().uuidString)")
        outputs.append(output)
        let surface = GhosttySurface()
        surfaces.append(surface)
        surface.start(
            TerminalSurfaceConfig(
                command: "/bin/sh",
                args: ["-c", "sleep \(Self.shellStartup); stty size > \"\(output.path)\"; sleep 100"],
                backingScale: backingScale))
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")
        return (surface, output)
    }

    private func size(at output: URL) -> String? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let text = try? String(contentsOf: output, encoding: .utf8), text.hasSuffix("\n") {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return nil
    }

    func test_aDetachedSurfaceLaidOutAfterStartReportsTheGridItWillMountAt() throws {
        let (mounted, mountedOutput) = try reportingSize(backingScale: nil)
        mounted.view.frame = frame
        window.contentView?.addSubview(mounted.view)
        let (detached, detachedOutput) = try reportingSize(backingScale: window.backingScaleFactor)
        detached.view.frame = frame

        let expected = try XCTUnwrap(size(at: mountedOutput), "the mounted shell never reported its size")
        let reported = try XCTUnwrap(size(at: detachedOutput), "the detached shell never reported its size")

        XCTAssertEqual(reported, expected, "the program read the default grid, not the canvas it will mount into")
        XCTAssertEqual(detached.cellMetrics?.columns, mounted.cellMetrics?.columns)
    }
}
