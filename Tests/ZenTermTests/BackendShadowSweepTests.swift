import AppKit
import XCTest

@testable import TerminalKit
@testable import ZenTerm

/// What libghostty's keymap is still holding under a ZenTerm pane, swept whole (ZEN-365).
///
/// The chrome resolves its keymap ahead of the responder chain and passes on everything it does
/// not claim, so the backend's keymap is live underneath ours the whole time. `GhosttyConfigWriter`
/// emits an `unbind` line for every chord ZenTerm answers itself or libghostty answers with an
/// action our apprt never implements, and what is left is `GhosttyUnboundChords.kept`.
///
/// This replaces the ZEN-360 baseline, which pinned only the chords under our own defaults. That
/// question is now the smaller half: an unbind that stops matching is invisible to it, because a
/// chord our chrome claims never reaches the backend either way. So the sweep walks the whole
/// typeable chord space instead and asserts on the exact surviving set. A pin bump that adds a
/// bind, moves one under a spelling we unbind, or drops one we kept, all turn it red.
///
/// A change here is not automatically a bug. The fix is usually to decide whether the move is
/// acceptable and then update the list. What it must never do is happen silently.
///
/// `key_is_binding` answers against a real surface's live config, so this needs one. It skips
/// rather than fails when `ghostty_surface_new` does, which is what happens on a locked screen.
@MainActor
final class BackendShadowSweepTests: XCTestCase {
    /// Keys that type a character, so the layout can resolve a keyCode for them. ghostty spells
    /// each as the character itself, which is what `Chord.key` already holds.
    private static let typedKeys: [String] = {
        var keys: [String] = "abcdefghijklmnopqrstuvwxyz0123456789".map { String($0) }
        keys += ["-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`"]
        return keys
    }()

    /// Keys that type nothing, so no layout lookup can reach them, under ghostty's own names for
    /// them. Bound in its defaults all the same, and three of the survivors live here.
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

        // A chord this keyboard cannot type has no keyCode to ask about. On a US layout that set is
        // empty, and a non-empty one means the machine's layout rather than a regression — but only
        // if the layout answered at all. Assert before skipping: a walk that resolved nothing is a
        // broken `KeyboardLayout.resolve`, and skipping on it would retire the only check over the
        // whole unbind list while reporting green.
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

    /// The probe has to be able to say no, or the sweep above is a list of false positives.
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

    /// A backend with no keymap of its own answers through the protocol extension, so a future
    /// one needs no code for this. `RecordingSurface` declares no `disposition`, which is the
    /// point: it reaches the extension's default the same way a new backend would.
    func test_aBackendWithNoKeymapIgnoresEverything() {
        XCTAssertEqual(
            RecordingSurface().disposition(of: TerminalKey(keyCode: 40, modifiers: .command)), .ignores)
    }

    /// Every modifier combination, including none: `escape` is bound bare, and a bind we missed on
    /// a bare key would be the worst one to miss.
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

    /// ghostty's trigger spelling, modifiers in the order `GhosttyUnboundChords` writes them.
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
