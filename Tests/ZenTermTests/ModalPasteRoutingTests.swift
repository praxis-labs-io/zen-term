import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// ⌘V while a modal text-field card is up must paste into that field, not the terminal behind it.
/// The Paste menu item uses the custom `pasteToSurface:` selector (the terminal surface has no
/// standard `paste:`), which bypasses the focused field editor and walks the responder chain by
/// name — where the window's delegate (`WindowController`) is reached before `NSApp`'s delegate.
/// So the modal-aware redirect has to live on `WindowController`, the responder that actually
/// receives the action; a copy in `AppDelegate` is shadowed and never runs.
@MainActor
final class ModalPasteRoutingTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    /// The user's real clipboard, snapshotted so the test's writes to `NSPasteboard.general` don't
    /// permanently clobber it — the production paste path reads the general pasteboard directly, so
    /// there's no private one to redirect to; restore-after is the workable guard.
    private var savedClipboard: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        savedClipboard = NSPasteboard.general.string(forType: .string)
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        Motion.isReduceMotionEnabled = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        NSPasteboard.general.clearContents()
        if let savedClipboard { NSPasteboard.general.setString(savedClipboard, forType: .string) }
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.showAndStart()
        c.window.makeKeyAndOrderFront(nil)
        controller = c
        return c
    }

    func test_paste_whileCommandPaletteUp_landsInTheField_notTheTerminal() throws {
        let c = makeWindow()
        let paneSurface = try XCTUnwrap(spawned.first, "the first tab spawns one pane surface")

        c.handle(.toggleCommandPalette)  // opens the palette and focuses its search field
        let editor = try XCTUnwrap(
            c.window.firstResponder as? NSTextView, "the palette's search field must hold focus")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("CLIPBOARD-PATH", forType: .string)

        // `WindowController` is the window's delegate, so the responder chain reaches its
        // `pasteToSurface:` (the Paste menu item's custom selector) before `NSApp`'s delegate —
        // this call IS what a ⌘V lands on.
        c.pasteToSurface(NSMenuItem())

        XCTAssertEqual(
            paneSurface.pastes, [],
            "paste must NOT reach the terminal while a modal text-field card is up")
        XCTAssertEqual(
            editor.string, "CLIPBOARD-PATH",
            "paste must land in the focused modal field")
    }
}
