import AppKit
import XCTest

@testable import TerminalKit

final class GhosttySurfaceChurnTests: XCTestCase {
    func test_rapidCreateDestroyKeepsSurfaceCreationAlive() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ZENTERM_CHURN_STRESS"] == "1",
            "stress harness — set ZENTERM_CHURN_STRESS=1 to run")

        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let iterations =
            ProcessInfo.processInfo.environment["ZENTERM_CHURN_ITERATIONS"].flatMap(Int.init) ?? 150
        let footprintBefore = Self.physFootprint()

        for iteration in 0..<iterations {
            let surface = GhosttySurface()
            surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
            window.contentView?.addSubview(surface.view)
            surface.start(TerminalSurfaceConfig(command: "/bin/sleep", args: ["100"]))
            guard surface.surfacePtr != nil else {
                XCTFail("ghostty_surface_new failed at iteration \(iteration) — teardown is leaking")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            surface.view.removeFromSuperview()
            surface.terminate()
            if surface.surfacePtr != nil { XCTFail("terminate() left surfacePtr live") }
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let footprintAfter = Self.physFootprint()
        let deltaMB = Double(footprintAfter - footprintBefore) / 1_048_576
        print("churn: \(iterations) surfaces, footprint delta \(String(format: "%.1f", deltaMB)) MB")
    }

    private static func physFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
