import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class SettingsFormBackdropWindowTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-form-backdrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        ConfigLoader.defaultRootOverrideForTesting = nil
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        controller = c
        return c
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func overlay<T: NSView>(_ type: T.Type, in c: WindowController) -> T? {
        descendants(of: c.window.contentView!).compactMap { $0 as? T }.first
    }

    private func openSettingsSection(titled title: String, button buttonTitle: String, in c: WindowController) throws {
        c.handle(.openSettings)
        let settings = try XCTUnwrap(overlay(SettingsOverlay.self, in: c))
        let nav = try XCTUnwrap(
            descendants(of: settings).compactMap { $0 as? SettingsNavRow }.first { $0.titleForTesting == title })
        _ = nav.accessibilityPerformPress()
        waitUntil(
            descendants(of: settings).contains { ($0 as? AppButton)?.title == buttonTitle },
            "the \(title) section to load")
        try XCTUnwrap(descendants(of: settings).compactMap { $0 as? AppButton }.first { $0.title == buttonTitle })
            .onTap()
    }

    private var escape: NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    }

    private func clickBackdrop(of form: ModalShell) throws {
        try XCTUnwrap(form.subviews.compactMap { $0 as? BackdropView }.first).mouseDown(with: NSEvent())
    }

    func test_sshHostForm_backdropClickClosesTheWholeStack() throws {
        let c = makeWindow()
        try openSettingsSection(titled: "Remote hosts", button: "＋ Add Host…", in: c)
        waitUntil(overlay(AddSSHHostOverlay.self, in: c) != nil, "the host form to open")

        try clickBackdrop(of: try XCTUnwrap(overlay(AddSSHHostOverlay.self, in: c)))

        XCTAssertFalse(c.isModalOverlayOpen)
    }

    func test_sshHostForm_escapeReturnsToSettings() throws {
        let c = makeWindow()
        try openSettingsSection(titled: "Remote hosts", button: "＋ Add Host…", in: c)
        waitUntil(overlay(AddSSHHostOverlay.self, in: c) != nil, "the host form to open")

        _ = try XCTUnwrap(overlay(AddSSHHostOverlay.self, in: c)).performKeyEquivalent(with: escape)

        XCTAssertTrue(c.isModalOverlayOpen)
        waitUntil(
            overlay(SettingsOverlay.self, in: c).map { !$0.isDismissing } == true, "Settings to return")
    }
}
