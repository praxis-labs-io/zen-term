import AppKit
import XCTest

@testable import TerminalKit
@testable import ZenTerm

final class ProgramTitleTests: XCTestCase {
    private var originalConfig: GeneralConfig!
    private var window: NSWindow!
    private var surfaces: [GhosttySurface] = []

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
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
        window.close()
        window = nil
        GeneralConfig.setCurrentForTesting(originalConfig)
        super.tearDown()
    }

    private func title(running command: String, in shell: String) throws -> String {
        var config = GeneralConfig.builtIn
        config.shell = shell
        GeneralConfig.setCurrentForTesting(config)
        let surface = GhosttySurface()
        surfaces.append(surface)
        surface.start(ShellLaunch.program(command, cwd: FileManager.default.temporaryDirectory))
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, surface.title != command {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return surface.title
    }

    func test_aProgramIsTitledWithItsCommandWhileItRuns() throws {
        let command = #"echo "it's" > /dev/null; sleep 30"#
        XCTAssertEqual(try title(running: command, in: "/bin/zsh"), command)
        XCTAssertEqual(try title(running: command, in: "/bin/bash"), command)
    }
}
