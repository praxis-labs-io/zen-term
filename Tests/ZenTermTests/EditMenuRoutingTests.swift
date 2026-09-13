import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class EditMenuRoutingTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
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
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        controller = c
        return c
    }

    private func send(_ selector: Selector, in c: WindowController) {
        c.window.firstResponder?.tryToPerform(selector, with: NSMenuItem())
    }

    private func focusedEditor(in c: WindowController, typing text: String) throws -> NSTextView {
        let editor = try XCTUnwrap(
            c.window.firstResponder as? NSTextView, "a field editor must hold the keyboard")
        editor.string = text
        editor.setSelectedRange(NSRange(location: text.count, length: 0))
        return editor
    }

    func test_selectAll_inTheFindBar_selectsTheField_notTheBuffer() throws {
        let c = makeWindow()
        let paneSurface = try XCTUnwrap(spawned.first, "the first tab spawns one pane surface")

        c.handle(.toggleSearch)
        let editor = try focusedEditor(in: c, typing: "needle")

        send(#selector(NSText.selectAll(_:)), in: c)

        XCTAssertEqual(
            editor.selectedRange(), NSRange(location: 0, length: 6),
            "⌘A must select the find field's own text")
        XCTAssertEqual(
            paneSurface.selectAllCount, 0,
            "and must not reach the buffer behind a field that holds the keyboard")
    }

    func test_copy_inTheFindBar_takesTheField_notTheTerminalSelection() throws {
        let c = makeWindow()
        let paneSurface = try XCTUnwrap(spawned.first)
        paneSurface.selectionText = "TERMINAL-SELECTION"

        c.handle(.toggleSearch)
        let editor = try focusedEditor(in: c, typing: "needle")
        editor.setSelectedRange(NSRange(location: 0, length: 6))
        NSPasteboard.general.clearContents()

        send(#selector(NSText.copy(_:)), in: c)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string), "needle",
            "⌘C must copy the field's selection, not the terminal's")
    }

    func test_paste_inTheFindBar_landsInTheField_notTheTerminal() throws {
        let c = makeWindow()
        let paneSurface = try XCTUnwrap(spawned.first)

        c.handle(.toggleSearch)
        let editor = try focusedEditor(in: c, typing: "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("CLIPBOARD-PATH", forType: .string)

        send(#selector(NSText.paste(_:)), in: c)

        XCTAssertEqual(editor.string, "CLIPBOARD-PATH", "⌘V must land in the find field")
        XCTAssertEqual(paneSurface.pastes, [], "and must not reach the terminal behind it")
    }

    func test_selectAll_whileCommandPaletteUp_selectsTheFilter_notTheBuffer() throws {
        let c = makeWindow()
        let paneSurface = try XCTUnwrap(spawned.first)

        c.handle(.toggleCommandPalette)
        let editor = try focusedEditor(in: c, typing: "git")

        send(#selector(NSText.selectAll(_:)), in: c)

        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 3))
        XCTAssertEqual(paneSurface.selectAllCount, 0)
    }

    func test_paste_whileCommandPaletteUp_landsInTheField_notTheTerminal() throws {
        let c = makeWindow()
        let paneSurface = try XCTUnwrap(spawned.first)

        c.handle(.toggleCommandPalette)
        let editor = try focusedEditor(in: c, typing: "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("CLIPBOARD-PATH", forType: .string)

        send(#selector(NSText.paste(_:)), in: c)

        XCTAssertEqual(
            paneSurface.pastes, [],
            "paste must NOT reach the terminal while a modal text-field card is up")
        XCTAssertEqual(editor.string, "CLIPBOARD-PATH", "paste must land in the focused modal field")
    }

    func test_selectAll_overACardWithNoField_touchesNothing() throws {
        let c = makeWindow()
        let paneSurface = try XCTUnwrap(spawned.first)

        c.handle(.openSettings)
        XCTAssertNil(
            c.window.firstResponder as? NSTextView,
            "Settings must land on a nav row for this test to be about a card with no field")

        send(#selector(NSText.selectAll(_:)), in: c)

        XCTAssertEqual(paneSurface.selectAllCount, 0)
    }

    func test_copyAndPaste_overACardWithNoField_touchTheTerminalNotAtAll() throws {
        let c = makeWindow()
        let paneSurface = try XCTUnwrap(spawned.first)
        paneSurface.selectionText = "TERMINAL-SELECTION"

        c.handle(.openSettings)
        XCTAssertNil(c.window.firstResponder as? NSTextView, "Settings must land on a nav row")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("CLIPBOARD-PATH", forType: .string)

        send(#selector(NSText.copy(_:)), in: c)
        send(#selector(NSText.paste(_:)), in: c)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string), "CLIPBOARD-PATH",
            "copy must not overwrite the clipboard with the buffer behind the card")
        XCTAssertEqual(
            paneSurface.pastes, [], "paste must not reach the terminal behind the card")
    }

    func test_selectAll_overAPane_reachesTheSurface() throws {
        let c = makeWindow()
        let paneSurface = try XCTUnwrap(spawned.first)
        XCTAssertNil(c.window.firstResponder as? NSTextView, "no field holds the keyboard")

        send(#selector(NSText.selectAll(_:)), in: c)

        XCTAssertEqual(paneSurface.selectAllCount, 1, "⌘A over a pane selects the buffer")
    }

    func test_selectAll_withAFocusedDrawer_reachesTheDrawer() throws {
        let c = makeWindow()
        let paneSurface = try XCTUnwrap(spawned.first)

        c.handle(.toggleBottomDrawer)
        let drawerSurface = try XCTUnwrap(spawned.dropFirst().first, "the drawer spawns a surface")

        send(#selector(NSText.selectAll(_:)), in: c)

        XCTAssertEqual(drawerSurface.selectAllCount, 1)
        XCTAssertEqual(paneSurface.selectAllCount, 0, "not the pane the drawer took focus from")
    }

    func test_selectAll_overAnOpenToolFloat_reachesTheFloat() throws {
        var config = GeneralConfig.builtIn
        config.floats = [
            ToolFloat(
                id: "btop", order: 0, title: "btop", icon: ToolFloatParser.defaultIcon,
                command: "btop", dir: nil, widthFraction: 0.85, heightFraction: 0.85,
                requiresGitRepo: false, persist: .window,
                toggle: Chord(command: true, shift: true, key: "b"))
        ]
        GeneralConfig.setCurrentForTesting(config)

        let c = makeWindow()
        c.floatsForTesting.resolveRepoRoot = { $1(GitRepo.repoRoot(for: $0)) }
        let paneSurface = try XCTUnwrap(spawned.first)

        c.handle(.toggleToolFloat("btop"))
        let floatSurface = try XCTUnwrap(
            spawned.first { $0.lastConfig?.args == ["-l", "-i", "-c", "btop"] },
            "the float spawns its own surface")

        send(#selector(NSText.selectAll(_:)), in: c)

        XCTAssertEqual(floatSurface.selectAllCount, 1)
        XCTAssertEqual(paneSurface.selectAllCount, 0, "not the pane behind the float")
    }

    func test_copy_overAPane_reachesTheSurface() throws {
        let c = makeWindow()
        let paneSurface = try XCTUnwrap(spawned.first)
        paneSurface.selectionText = "TERMINAL-SELECTION"
        NSPasteboard.general.clearContents()

        send(#selector(NSText.copy(_:)), in: c)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "TERMINAL-SELECTION")
    }
}
