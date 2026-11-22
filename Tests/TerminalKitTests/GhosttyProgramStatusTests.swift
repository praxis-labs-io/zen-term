import AppKit
import GhosttyKit
import XCTest

@testable import TerminalKit

final class GhosttyProgramStatusTests: XCTestCase {
    func test_supportQueryIsAnswered() throws {
        let reply = try runInSurface(
            ["stty raw -echo", "printf '\\033]7501;?\\007'", "dd bs=1 count=8 2>/dev/null > \"$OUT\""],
            until: { $0.count >= 8 })
        XCTAssertEqual(String(decoding: reply, as: UTF8.self), "\u{1b}]7501;?")
    }

    func test_eachReportedStateCrossesTheSeam() {
        let cases: [(ghostty_action_program_status_state_e, ghostty_action_program_status_kind_e, Expected)] = [
            (Self.idle, Self.noKind, .idle),
            (Self.working, Self.noKind, .working),
            (Self.done, Self.noKind, .done),
            (Self.blocked, GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION, .blocked(.permission)),
            (Self.blocked, GHOSTTY_PROGRAM_STATUS_KIND_QUESTION, .blocked(.question)),
            (Self.blocked, GHOSTTY_PROGRAM_STATUS_KIND_AUTH, .blocked(.auth)),
            (Self.blocked, Self.noKind, .blocked(nil)),
            (GHOSTTY_PROGRAM_STATUS_STATE_ERROR, Self.noKind, .failed),
        ]
        for (state, kind, expected) in cases {
            XCTAssertEqual(Self.mapped(state, kind)?.state, expected, "\(state) \(kind)")
        }
    }

    private typealias Expected = TerminalProgramStatus.State
    private static let idle = GHOSTTY_PROGRAM_STATUS_STATE_IDLE
    private static let working = GHOSTTY_PROGRAM_STATUS_STATE_WORKING
    private static let done = GHOSTTY_PROGRAM_STATUS_STATE_DONE
    private static let blocked = GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED
    private static let noKind = GHOSTTY_PROGRAM_STATUS_KIND_NONE

    func test_clearRemovesTheStatus() {
        XCTAssertNil(Self.mapped(GHOSTTY_PROGRAM_STATUS_STATE_CLEAR, GHOSTTY_PROGRAM_STATUS_KIND_NONE))
    }

    func test_appMessageAndTitleCrossTheSeamWithoutControlCharacters() {
        let status = "claude-code".withCString { app in
            "approve\u{1b}[31m Write\u{7}".withCString { msg in
                "Review\u{7} PR".withCString { title in
                    GhosttySurface.programStatus(
                        ghostty_action_program_status_s(
                            state: GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED, kind: GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION,
                            app: app, msg: msg, title: title))
                }
            }
        }
        XCTAssertEqual(status?.app, "claude-code")
        XCTAssertEqual(status?.message, "approve[31m Write")
        XCTAssertEqual(status?.title, "Review PR")
    }

    func test_aBlockedReportReachesTheDelegate() throws {
        let spy = StatusSpy()
        let message = Data("approve Write".utf8).base64EncodedString()
        let title = Data("Fix the login bug".utf8).base64EncodedString()
        _ = try runInSurface(
            [
                "printf '\\033]7501;state=blocked:app=claude-code:kind=permission:msg=\(message):title=\(title)\\007'",
                "sleep 5",
            ], delegate: spy, until: { _ in !spy.statuses.isEmpty })
        XCTAssertEqual(
            spy.statuses.first,
            TerminalProgramStatus(
                state: .blocked(.permission), app: "claude-code", message: "approve Write",
                title: "Fix the login bug"))
    }

    func test_aSubRecordsReportNeverReachesTheDelegate() throws {
        let spy = StatusSpy()
        _ = try runInSurface(
            [
                "printf '\\033]7501;state=error:app=claude-code:id=deploy\\007'",
                "printf '\\033]7501;state=working:app=claude-code\\007'",
                "sleep 5",
            ], delegate: spy, until: { _ in !spy.statuses.isEmpty })
        XCTAssertEqual(spy.statuses.map { $0?.state }, [.working])
    }

    private static func mapped(
        _ state: ghostty_action_program_status_state_e, _ kind: ghostty_action_program_status_kind_e
    ) -> TerminalProgramStatus? {
        "".withCString { empty in
            GhosttySurface.programStatus(
                ghostty_action_program_status_s(state: state, kind: kind, app: empty, msg: empty, title: empty))
        }
    }

    private final class StatusSpy: TerminalSurfaceDelegate {
        var statuses: [TerminalProgramStatus?] = []
        func surface(_ s: TerminalSurface, programStatusDidChange status: TerminalProgramStatus?) {
            statuses.append(status)
        }
    }

    private func runInSurface(
        _ lines: [String], delegate: TerminalSurfaceDelegate? = nil, until done: (Data) -> Bool
    ) throws -> Data {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFront(nil)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let stem = NSTemporaryDirectory() + "zen7501-\(UUID().uuidString)"
        let output = "\(stem)-out"
        let script = "\(stem).sh"
        defer {
            try? FileManager.default.removeItem(atPath: output)
            try? FileManager.default.removeItem(atPath: script)
        }
        try (["OUT='\(output)'"] + lines).joined(separator: "\n").write(
            toFile: script, atomically: true, encoding: .utf8)

        let surface = GhosttySurface()
        surface.delegate = delegate
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: [script]))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")

        let deadline = Date().addingTimeInterval(10)
        var data = Data()
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            data = FileManager.default.contents(atPath: output) ?? Data()
            if done(data) { return data }
        }
        XCTFail("the surface did not finish within 10s; got \(String(decoding: data, as: UTF8.self).debugDescription)")
        return data
    }
}
