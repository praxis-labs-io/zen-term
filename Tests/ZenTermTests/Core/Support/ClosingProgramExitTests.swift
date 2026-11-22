import AppKit
import XCTest

@testable import TerminalKit
@testable import ZenTerm

// A launched pane reads its exit code from the D mark when the child exits, so the mark has to land first.
final class ClosingProgramExitTests: XCTestCase {
    private final class Recorder: NSObject, TerminalSurfaceDelegate {
        var events: [String] = []

        func surface(_ s: TerminalSurface, commandDidFinish result: TerminalCommandResult) {
            events.append("finished \(result.exitCode.map(String.init) ?? "nil")")
        }

        func surfaceDidExit(_ s: TerminalSurface, code: Int32?) { events.append("exited") }
    }

    private var originalConfig: GeneralConfig!

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
    }

    override func tearDown() {
        GeneralConfig.setCurrentForTesting(originalConfig)
        super.tearDown()
    }

    private func events(running command: String, in shell: String) throws -> [String] {
        var config = GeneralConfig.builtIn
        config.shell = shell
        GeneralConfig.setCurrentForTesting(config)
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }

        let recorder = Recorder()
        let surface = GhosttySurface()
        surface.delegate = recorder
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        surface.start(
            ShellLaunch.program(command, cwd: FileManager.default.temporaryDirectory, exitClosesPane: true))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !recorder.events.contains("exited") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return recorder.events
    }

    func test_theExitMarkLandsBeforeTheChildExits() throws {
        XCTAssertEqual(try events(running: "(exit 7)", in: "/bin/zsh"), ["finished 7", "exited"])
        XCTAssertEqual(try events(running: "true", in: "/bin/bash"), ["finished 0", "exited"])
    }
}
