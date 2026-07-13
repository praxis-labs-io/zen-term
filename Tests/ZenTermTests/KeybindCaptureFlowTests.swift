import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the keybind capture flow (ZEN-105): begin capture on a row, feed key
/// events through the real `KeybindCapturing` seam, and assert the rebind lands (or doesn't).
/// `resolve()` was tested; the capture / cancel / conflict / reset path — shipped in the last week
/// — was not, and a bug here bricks all keyboard input while recording.
///
/// The config write→reload roundtrip is sandboxed via `ConfigLoader.defaultRootOverrideForTesting`
/// so the tests never touch the real config. (Stacked on the ZEN-104 seam.)
final class KeybindCaptureFlowTests: XCTestCase {
    /// A `KeybindCapturing` double: stores the section's handler so a test can feed events, and
    /// counts `endCapture` so "still armed vs restored" is observable.
    private final class FakeCapturer: KeybindCapturing {
        private(set) var handler: ((NSEvent) -> Void)?
        private(set) var endCount = 0
        var isArmed: Bool { handler != nil }
        func beginCapture(_ handler: @escaping (NSEvent) -> Void) { self.handler = handler }
        func endCapture() { handler = nil; endCount += 1 }
        func feed(_ event: NSEvent) { handler?(event) }
    }

    private var tempRoot: URL!
    private var section: SettingsKeybindsSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-keybinds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()  // keymap == defaults (empty temp config)
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    // MARK: event helpers

    private func keyDown(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
            keyCode: code)!
    }

    /// A `keyDown` matching a letter-key chord (keyCode 0 is fine — non-special keys decode from
    /// `charactersIgnoringModifiers`, not the code).
    private func event(for chord: Chord) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if chord.command { flags.insert(.command) }
        if chord.shift { flags.insert(.shift) }
        if chord.option { flags.insert(.option) }
        if chord.control { flags.insert(.control) }
        return keyDown(chord.key, code: 0, flags: flags)
    }

    /// A chord vanishingly unlikely to collide with any default: all four modifiers + a letter.
    private let novelChord = Chord(command: true, shift: true, option: true, control: true, key: "p")

    // MARK: harness

    private func mountSection(_ capturer: FakeCapturer) -> SettingsKeybindsSection {
        let section = SettingsKeybindsSection(capturer: capturer)
        self.section = section
        let detail = section.makeDetailView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        self.hostWindow = window
        window.contentView?.addSubview(detail)
        detail.frame = window.contentView!.bounds
        return section
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func row(for action: KeyInterceptor.ReservedChord) -> KeybindRow {
        descendants(of: hostWindow!.contentView!).compactMap { $0 as? KeybindRow }
            .first { $0.action == action }!
    }

    private var liveKeymap: [Chord: KeyInterceptor.ReservedChord] { GeneralConfig.current.keymap }

    // MARK: tests

    func test_validChord_commitsRebindAndEndsCapture() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        let oldChord = liveKeymap.first { $0.value == .newTab }!.key  // new-tab's chord before the rebind
        row(for: .newTab).chip.onActivate?()
        XCTAssertTrue(capturer.isArmed)

        capturer.feed(event(for: novelChord))

        XCTAssertEqual(liveKeymap[novelChord], .newTab, "the novel chord should now open a new tab")
        // A rebind is a MOVE, not an add: the old chord must be freed, else both would fire new-tab.
        XCTAssertNotEqual(liveKeymap[oldChord], .newTab, "the previous new-tab chord is released on rebind")
        XCTAssertEqual(capturer.endCount, 1, "a commit ends the capture")
        XCTAssertFalse(capturer.isArmed)
    }

    func test_esc_cancelsWithoutRebinding() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        let before = liveKeymap
        row(for: .newTab).chip.onActivate?()

        capturer.feed(keyDown("\u{1b}", code: 53))  // Esc

        XCTAssertEqual(capturer.endCount, 1, "Esc ends the capture")
        XCTAssertFalse(capturer.isArmed)
        XCTAssertNil(liveKeymap[novelChord])
        XCTAssertEqual(liveKeymap, before, "Esc must not change any binding")
    }

    func test_delete_resetsReboundActionToDefault() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)

        // First rebind new-tab to the novel chord…
        row(for: .newTab).chip.onActivate?()
        capturer.feed(event(for: novelChord))
        XCTAssertEqual(liveKeymap[novelChord], .newTab)

        // …then capture again and press Delete → back to the built-in default(s).
        row(for: .newTab).chip.onActivate?()
        let endCountBeforeDelete = capturer.endCount
        capturer.feed(keyDown("\u{7f}", code: 51))  // Delete

        // Delete must END the capture, not just reset the mapping — leaving it armed is the
        // input-bricking scenario these tests guard against.
        XCTAssertEqual(capturer.endCount, endCountBeforeDelete + 1, "Delete ends the capture")
        XCTAssertFalse(capturer.isArmed)
        XCTAssertNil(liveKeymap[novelChord], "the reset drops the custom chord")
        let defaultNewTab = KeymapDefaults.map.first { $0.value == .newTab }!.key
        XCTAssertEqual(liveKeymap[defaultNewTab], .newTab, "new-tab is back on its default chord")
    }

    func test_conflictingChord_isBlockedAndStaysArmed() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        // A chord currently bound to a *different* action (new-tab).
        let newTabChord = liveKeymap.first { $0.value == .newTab }!.key
        let before = liveKeymap

        row(for: .closePane).chip.onActivate?()
        capturer.feed(event(for: newTabChord))

        XCTAssertTrue(capturer.isArmed, "a conflict keeps the capture armed for another try")
        XCTAssertEqual(capturer.endCount, 0)
        XCTAssertEqual(liveKeymap, before, "a conflicting chord must not rebind anything")
    }

    func test_modifierlessChord_isRejectedAndStaysArmed() {
        let capturer = FakeCapturer()
        _ = mountSection(capturer)
        let before = liveKeymap

        row(for: .newTab).chip.onActivate?()
        capturer.feed(keyDown("k", code: 40))  // bare 'k', no modifiers

        XCTAssertTrue(capturer.isArmed, "a modifier-less chord is rejected but keeps waiting")
        XCTAssertEqual(capturer.endCount, 0)
        XCTAssertEqual(liveKeymap, before)
    }

    /// The safeguard at `WindowController.tearDown`: closing a window while a Settings capture is
    /// armed must end it — otherwise the shared interceptor stays in capture mode and swallows every
    /// keystroke in every other window.
    func test_windowClose_endsAnArmedCapture() {
        let originalBackend = TerminalSurfaceFactory.backend
        TerminalSurfaceFactory.backend = .swiftTerm
        defer { TerminalSurfaceFactory.backend = originalBackend }

        let capturer = FakeCapturer()
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), initialCWD: nil)
        controller.keybindCapturer = capturer
        capturer.beginCapture { _ in }  // arm it, as if a Settings row were recording
        XCTAssertTrue(capturer.isArmed)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertFalse(capturer.isArmed, "window close must end the armed capture")
        XCTAssertGreaterThanOrEqual(capturer.endCount, 1)
    }
}
