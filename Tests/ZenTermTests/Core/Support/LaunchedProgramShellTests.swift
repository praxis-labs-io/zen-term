import AppKit
import XCTest

@testable import TerminalKit
@testable import ZenTerm

// A launched program runs under the user's shell, which reports its exit code and must leave it the pane's foreground.
final class LaunchedProgramShellTests: XCTestCase {
    private final class Recorder: NSObject, TerminalSurfaceDelegate {
        var events: [String] = []

        func surface(_ s: TerminalSurface, commandDidFinish result: TerminalCommandResult) {
            events.append("finished \(result.exitCode.map(String.init) ?? "nil")")
        }

        func surfaceDidExit(_ s: TerminalSurface, code: Int32?) { events.append("exited") }
    }

    private var originalConfig: GeneralConfig!
    private var window: NSWindow!
    private var surfaces: [GhosttySurface] = []
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalConfig = GeneralConfig.current
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("zen-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for surface in surfaces {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        surfaces = []
        window.close()
        window = nil
        try? FileManager.default.removeItem(at: scratch)
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private func launch(
        _ command: String, in shell: String, exitClosesPane: Bool = true, env: [String: String] = [:]
    ) throws -> (surface: GhosttySurface, recorder: Recorder) {
        var config = GeneralConfig.builtIn
        config.shell = shell
        GeneralConfig.setCurrentForTesting(config)
        let recorder = Recorder()
        let surface = GhosttySurface()
        surfaces.append(surface)
        surface.delegate = recorder
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        surface.start(
            ShellLaunch.program(
                command, cwd: scratch, env: env, exitClosesPane: exitClosesPane, marksExit: !exitClosesPane))
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")
        return (surface, recorder)
    }

    private func run(until done: () -> Bool, timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !done() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func events(running command: String, in shell: String, env: [String: String] = [:]) throws -> [String] {
        let recorder = try launch(command, in: shell, env: env).recorder
        run { recorder.events.contains("exited") && recorder.events.contains(where: finished) }
        return recorder.events
    }

    private func events(keeping command: String, in shell: String) throws -> [String] {
        let (surface, recorder) = try launch(command, in: shell, exitClosesPane: false)
        run { recorder.events.contains(where: finished) || recorder.events.contains("exited") }
        run { recorder.events.contains("exited") || atShell(surface) }
        return recorder.events
    }

    private func finished(_ event: String) -> Bool { event.hasPrefix("finished") }

    private func atShell(_ surface: GhosttySurface) -> Bool {
        surface.foregroundProcessGroupID.map { ForegroundGroup.isShell($0) } ?? false
    }

    private func foregroundProgram(of surface: GhosttySurface, becoming expected: String) -> String? {
        var program: String?
        run(
            until: {
                program = surface.foregroundProcessGroupID.flatMap(ProcessArguments.programName(of:))
                return program == expected
            }, timeout: 15)
        return program
    }

    private func agentNamedClaude() throws -> String {
        let agent = scratch.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: agent, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
        return agent.path
    }

    func test_theShellReportsTheLaunchedProgramsExitCodeAroundItsExit() throws {
        XCTAssertEqual(try events(running: "(exit 7)", in: "/bin/zsh").sorted(), ["exited", "finished 7"])
        XCTAssertEqual(try events(running: "true", in: "/bin/bash").sorted(), ["exited", "finished 0"])
    }

    func test_aCommandEndingInTheShellsOwnExitStillReportsItsCode() throws {
        XCTAssertEqual(try events(running: "exit 3", in: "/bin/zsh").sorted(), ["exited", "finished 3"])
        XCTAssertEqual(try events(running: "sleep 1; exit 5", in: "/bin/bash").sorted(), ["exited", "finished 5"])
        XCTAssertEqual(try events(running: "exit 6", in: "/bin/sh").sorted(), ["exited", "finished 6"])
    }

    func test_aCommandThatSetsItsOwnExitTrapStillReportsItsCode() throws {
        XCTAssertEqual(
            try events(running: "trap 'echo bye' EXIT; exit 4", in: "/bin/zsh").sorted(), ["exited", "finished 4"])
        XCTAssertEqual(
            try events(running: "trap 'echo bye' EXIT; false", in: "/bin/bash").sorted(), ["exited", "finished 1"])
    }

    func test_anExitTrapFromTheUsersStartupFilesStillRuns() throws {
        let marker = scratch.appendingPathComponent("rc-trap-ran")
        let rc = scratch.appendingPathComponent("rc.sh")
        try "trap 'echo ran > \"\(marker.path)\"' EXIT\n".write(to: rc, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try events(running: "true", in: "/bin/sh", env: ["ENV": rc.path]).sorted(), ["exited", "finished 0"])
        run { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the startup file's EXIT trap never ran")
    }

    func test_aKeptPaneWhoseCommandEndsInTheShellsOwnExitReportsItsCodeAndStaysOpen() throws {
        XCTAssertEqual(try events(keeping: "exit 5", in: "/bin/zsh"), ["finished 5"])
        XCTAssertEqual(try events(keeping: "sleep 1; exit 2", in: "/bin/bash"), ["finished 2"])
    }

    func test_theLaunchedCommandIsThePanesForegroundProgram() throws {
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
            for closes in [true, false] {
                let surface = try launch("sleep 100", in: shell, exitClosesPane: closes).surface
                XCTAssertEqual(foregroundProgram(of: surface, becoming: "sleep"), "sleep", "\(shell), closes \(closes)")
                XCTAssertFalse(atShell(surface), "\(shell), closes \(closes)")
            }
        }
    }

    func test_aLaunchedAgentIsThePanesForegroundProgram() throws {
        let claude = try agentNamedClaude()
        for shell in ["/bin/zsh", "/bin/bash"] {
            for closes in [true, false] {
                let surface = try launch("\(claude) 100", in: shell, exitClosesPane: closes).surface
                XCTAssertEqual(
                    foregroundProgram(of: surface, becoming: "claude"), "claude", "\(shell), closes \(closes)")
            }
        }
    }

    // An interactive zsh drops the rest of its `-c` list once a job dies of SIGINT, so it prints no mark.
    func test_interruptingTheForegroundGroupEndsTheLaunchedCommand() throws {
        for (shell, ended) in [("/bin/zsh", ["exited"]), ("/bin/bash", ["exited", "finished 130"])] {
            let (surface, recorder) = try launch("sleep 100", in: shell)
            XCTAssertEqual(foregroundProgram(of: surface, becoming: "sleep"), "sleep", shell)
            let group = try XCTUnwrap(surface.foregroundProcessGroupID)
            guard group != getpgrp() else { return XCTFail("a signal to the test's own group would end the test run") }
            XCTAssertTrue(ControlResponder.interrupt(group: group))
            run { recorder.events.sorted() == ended }
            XCTAssertEqual(recorder.events.sorted(), ended, shell)
        }
    }
}
