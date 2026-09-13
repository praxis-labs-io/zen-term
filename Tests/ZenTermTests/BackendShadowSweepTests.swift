import AppKit
import XCTest

@testable import TerminalKit
@testable import ZenTerm

@MainActor
final class BackendShadowSweepTests: XCTestCase {
    private static let typedKeys: [String] = {
        var keys: [String] = "abcdefghijklmnopqrstuvwxyz0123456789".map { String($0) }
        keys += ["-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`"]
        return keys
    }()

    private static let namedKeys: [(String, UInt16)] = [
        ("arrow_left", 123), ("arrow_right", 124), ("arrow_down", 125), ("arrow_up", 126),
        ("enter", 36), ("escape", 53), ("tab", 48), ("backspace", 51), ("space", 49),
        ("home", 115), ("end", 119), ("page_up", 116), ("page_down", 121),
    ]

    func test_theOnlyBindsLeftUnderAPaneAreTheOnesWeKept() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let surface = GhosttySurface()
        surface.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(surface.view)
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", "sleep 100"]))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed (a locked screen does this)")

        var measured: Set<String> = []
        var unreachable = 0
        for (command, shift, option, control) in Self.modifierSets {
            for key in Self.typedKeys {
                let chord = Chord(
                    command: command, shift: shift, option: option, control: control, key: key)
                guard let terminalKey = TerminalKey(chord: chord) else {
                    unreachable += 1
                    continue
                }
                guard surface.disposition(of: terminalKey) != .ignores else { continue }
                measured.insert(Self.token(command, shift, option, control, key))
            }
            for (name, keyCode) in Self.namedKeys {
                var modifiers: NSEvent.ModifierFlags = []
                if command { modifiers.insert(.command) }
                if shift { modifiers.insert(.shift) }
                if option { modifiers.insert(.option) }
                if control { modifiers.insert(.control) }
                let terminalKey = TerminalKey(keyCode: keyCode, modifiers: modifiers)
                guard surface.disposition(of: terminalKey) != .ignores else { continue }
                measured.insert(Self.token(command, shift, option, control, name))
            }
        }

        XCTAssertLessThan(
            unreachable, Self.typedKeys.count * Self.modifierSets.count,
            "no chord resolved: the layout walk is broken, which is not a layout difference")
        try XCTSkipUnless(unreachable == 0, "layout cannot type every probed key; not a US layout")

        let kept = Set(GhosttyUnboundChords.kept)
        XCTAssertEqual(
            measured.subtracting(kept), [],
            "libghostty still binds these and nothing in ZenTerm names them. Either add the "
                + "trigger to GhosttyUnboundChords.triggers, or decide to keep it and say so.")
        XCTAssertEqual(
            kept.subtracting(measured), [],
            "these were kept on purpose and the backend no longer binds them. An unbind spelling "
                + "that over-matched, or a pin bump that dropped the bind.")
    }

    func test_aChordTheBackendDoesNotBindReportsIgnores() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let surface = GhosttySurface()
        surface.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(surface.view)
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", "sleep 100"]))
        defer {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed (a locked screen does this)")

        let bare = try XCTUnwrap(TerminalKey(chord: Chord(command: true, key: "b")))
        XCTAssertEqual(surface.disposition(of: bare), .ignores, "nothing binds ⌘B")
    }

    func test_aBackendWithNoKeymapIgnoresEverything() {
        XCTAssertEqual(
            RecordingSurface().disposition(of: TerminalKey(keyCode: 40, modifiers: .command)), .ignores)
    }

    private static let modifierSets: [(Bool, Bool, Bool, Bool)] = {
        var sets: [(Bool, Bool, Bool, Bool)] = []
        for command in [false, true] {
            for shift in [false, true] {
                for option in [false, true] {
                    for control in [false, true] {
                        sets.append((command, shift, option, control))
                    }
                }
            }
        }
        return sets
    }()

    private static func token(
        _ command: Bool, _ shift: Bool, _ option: Bool, _ control: Bool, _ key: String
    ) -> String {
        var token = ""
        if command { token += "cmd+" }
        if shift { token += "shift+" }
        if option { token += "opt+" }
        if control { token += "ctrl+" }
        return token + key
    }
}
