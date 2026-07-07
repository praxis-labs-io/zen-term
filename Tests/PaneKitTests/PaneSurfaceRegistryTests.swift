import AppKit
import TerminalKit
import XCTest

@testable import PaneKit

/// A seam-conforming fake with stable identity and a terminate flag.
private final class FakeSurface: NSObject, TerminalSurface {
    let view = NSView()
    weak var delegate: TerminalSurfaceDelegate?
    var title = ""
    var isFocused = false
    private(set) var terminated = false
    func start(_ config: TerminalSurfaceConfig) {}
    func focus() {}
    func terminate() { terminated = true }
    func paste(_ text: String) {}
    func copySelection() -> String? { nil }
    func scrollToBottom() {}
}

final class PaneSurfaceRegistryTests: XCTestCase {
    func test_retainedLeafKeepsSameSurfaceInstance_acrossSplitAndClose() {
        let registry = PaneSurfaceRegistry(makeSurface: { FakeSurface() })

        // Split: create A.
        registry.apply(paneDiff(from: [], to: [PaneID(1)]))
        let a1 = registry.surface(for: PaneID(1))
        XCTAssertNotNil(a1)

        // Split again: create B, retain A. A must be the SAME instance.
        let created = registry.apply(paneDiff(from: [PaneID(1)], to: [PaneID(1), PaneID(2)]))
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.id, PaneID(2))
        XCTAssertTrue(registry.surface(for: PaneID(1)) === a1, "retained leaf's surface was recreated")

        // Close B: B terminated + removed, A untouched.
        let bSurface = registry.surface(for: PaneID(2)) as? FakeSurface
        registry.apply(paneDiff(from: [PaneID(1), PaneID(2)], to: [PaneID(1)]))
        XCTAssertNil(registry.surface(for: PaneID(2)))
        XCTAssertEqual(bSurface?.terminated, true)
        XCTAssertTrue(registry.surface(for: PaneID(1)) === a1)
        XCTAssertEqual(registry.ids, [PaneID(1)])
    }

    func test_terminateAll_terminatesEverySurfaceAndEmpties() {
        let registry = PaneSurfaceRegistry(makeSurface: { FakeSurface() })
        registry.apply(paneDiff(from: [], to: [PaneID(1), PaneID(2), PaneID(3)]))
        let surfaces = [PaneID(1), PaneID(2), PaneID(3)].map { registry.surface(for: $0) as? FakeSurface }

        registry.terminateAll()

        XCTAssertTrue(registry.ids.isEmpty)
        XCTAssertTrue(surfaces.allSatisfy { $0?.terminated == true }, "terminateAll left a surface running")
    }
}
