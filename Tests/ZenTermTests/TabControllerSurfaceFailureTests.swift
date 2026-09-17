import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class TabControllerSurfaceFailureTests: WindowTestCase {
    private var window: NSWindow?
    private var controller: TabController?

    override func tearDown() {
        controller?.shutdown()
        controller = nil
        window = nil
        super.tearDown()
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func test_commandCompletionRelaysFromDrawerToWindowOwner() throws {
        var spawned: [RecordingSurface] = []
        let controller = TabController(
            initialCWD: nil,
            makeSurface: {
                let surface = RecordingSurface()
                spawned.append(surface)
                return surface
            })
        self.controller = controller
        controller.start()
        controller.toggleBottomDrawer()
        let drawer = try XCTUnwrap(spawned.last)
        var received: TerminalCommandResult?
        controller.onCommandFinished = { received = $1 }
        let result = TerminalCommandResult(exitCode: 2, duration: 18)

        drawer.delegate?.surface(drawer, commandDidFinish: result)

        XCTAssertEqual(received, result)
    }

    func test_bottomDrawerSurfaceFailsToStart_warnsAndTearsDown() {
        var armFailure = false
        var armedDrawer: RecordingSurface?
        let controller = TabController(
            initialCWD: nil,
            makeSurface: {
                let surface = RecordingSurface()
                if armFailure {
                    surface.failOnStart = true
                    armedDrawer = surface
                }
                return surface
            })
        self.controller = controller

        var toasts: [ToastContent] = []
        controller.onRequestToast = { toasts.append($0) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView?.addSubview(controller.view)
        controller.view.layoutSubtreeIfNeeded()
        self.window = window

        armFailure = true
        controller.toggleBottomDrawer()
        armFailure = false
        guard let drawer = armedDrawer else {
            return XCTFail("opening the drawer must spawn its surface")
        }

        drainMainQueue()

        XCTAssertTrue(
            toasts.contains { $0.variant == .warning },
            "a dead drawer surfaces a warning toast (identity dispatch matched)")
        XCTAssertTrue(drawer.terminated, "the dead drawer is torn down, not left mounted")
    }
}
