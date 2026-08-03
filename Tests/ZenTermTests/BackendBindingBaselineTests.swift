import AppKit
import XCTest

@testable import TerminalKit
@testable import ZenTerm

/// What libghostty's own keymap does with each of our default chords, pinned.
///
/// The chrome resolves its keymap ahead of the responder chain and passes on everything it does
/// not claim, so the backend's keymap is live underneath ours the whole time. That has been true
/// since the beginning and nothing measured it: the reference table in ZEN-10 was read out of
/// ghostty's source, and a pin bump can move a bind under one of our chords with nothing to notice.
///
/// This asks the running library instead. A change here is not automatically a bug, and the fix is
/// usually to update the baseline after deciding the move is fine. What it must never do is happen
/// silently. Lives with the ZEN-320 pin-bump checks in spirit.
///
/// `key_is_binding` answers against a real surface's live config, so this needs one. It skips
/// rather than fails when `ghostty_surface_new` does, which is what happens on a locked screen.
@MainActor
final class BackendBindingBaselineTests: XCTestCase {
    /// Every default chord whose disposition is anything but `ignores`, by config token.
    ///
    /// Read it as: even if the chrome stopped claiming this chord tomorrow, here is what the pane
    /// would do with it. Absent from this map means the backend has no bind on that chord at all.
    ///
    /// `mayClaim` is the interesting column and the one a `Bool` would have lost. Those binds run
    /// only when their action would do something and otherwise let the key through, so they are
    /// not chords the backend has taken from us.
    /// Measured, not transcribed, and the difference showed up immediately: ⌘1 through ⌘9, ⌘, and
    /// ⌘⇧J are all bound in libghostty and appear nowhere in ZEN-10's hand-read table. ⌘⇧-, which
    /// ZEN-121 took for `split_horizontal`, is genuinely free.
    private static let baseline: [String: ChordDisposition] = [
        "cmd+k": .mayClaim,  // clear_screen
        "cmd+t": .claims,  // new_tab
        "cmd+n": .claims,  // new_window
        "cmd+w": .claims,  // close_surface
        "cmd+d": .claims,  // new_split right
        "cmd+f": .mayClaim,  // start_search
        "cmd+j": .mayClaim,  // scroll_to_selection
        "cmd+,": .claims,  // open_config
        "cmd+[": .claims,  // goto_split previous
        "cmd+]": .claims,  // goto_split next
        "cmd+=": .claims,  // increase_font_size
        "cmd+-": .claims,  // decrease_font_size
        "cmd+0": .claims,  // reset_font_size
        "cmd+shift+f": .mayClaim,  // end_search
        "cmd+shift+j": .claims,  // write_screen_file paste
        "cmd+shift+p": .claims,  // toggle_command_palette
        // goto_tab 1...9. Deliberately not performable upstream, so a tab shortcut keeps working.
        "cmd+1": .claims, "cmd+2": .claims, "cmd+3": .claims, "cmd+4": .claims, "cmd+5": .claims,
        "cmd+6": .claims, "cmd+7": .claims, "cmd+8": .claims, "cmd+9": .claims,
    ]

    func test_theBackendsBindsUnderOurDefaultsMatchTheBaseline() throws {
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

        var measured: [String: ChordDisposition] = [:]
        var unreachable: [String] = []
        for chord in KeymapDefaults.map.keys {
            guard let key = TerminalKey(chord: chord) else {
                unreachable.append(chord.configToken)
                continue
            }
            let disposition = surface.disposition(of: key)
            if disposition != .ignores { measured[chord.configToken] = disposition }
        }

        // A chord this keyboard cannot type has no keyCode to ask about. On a US layout that set is
        // empty, and a non-empty one here means the machine's layout, not a regression, but only
        // if the layout answered at all. A walk that resolved nothing puts every chord in
        // `unreachable`, and skipping on that would retire the check below without saying so.
        XCTAssertLessThan(
            unreachable.count, KeymapDefaults.map.count,
            "no chord resolved: the layout walk is broken, which is not a layout difference")
        try XCTSkipUnless(
            unreachable.isEmpty, "layout cannot type \(unreachable.sorted()); not a US-style layout")

        XCTAssertEqual(
            measured, Self.baseline,
            "libghostty's binds under our defaults moved. Decide whether each change is acceptable, "
                + "then update the baseline. Do not update it without reading what moved.")
    }

    /// The probe has to be able to say no, or the baseline above is a list of false positives.
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
}
