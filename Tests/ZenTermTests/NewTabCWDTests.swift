import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Where ⌘T starts. A tab used to inherit the focused pane's cwd unconditionally, which is a split's
/// rule applied to a tab: open a second piece of work and you land back in the first one's repo.
/// Home is the default now, and `tab-inherit-cwd` brings the old behavior back.
///
/// Driven through the real `.newTab` command and asserted on the cwd the spawned surface was
/// actually started with, because the value is decided in `newTab()` and handed down through
/// `ShellLaunch` — reading the config field back would agree with any bug in between.
@MainActor
final class NewTabCWDTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-new-tab-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        Motion.isReduceMotionEnabled = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// A window whose pane sits in `root`, so an inherited cwd is distinguishable from home.
    private func makeWindowInRoot() throws -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        c.showAndStart()
        controller = c
        try XCTUnwrap(spawned.first).currentDirectory = root
        return c
    }

    private func inheritCWD(_ on: Bool) {
        var config = GeneralConfig.builtIn
        config.tabInheritCWD = on
        GeneralConfig.setCurrentForTesting(config)
    }

    func test_newTab_startsAtHomeByDefault() throws {
        XCTAssertFalse(GeneralConfig.builtIn.tabInheritCWD, "home is the shipped default")
        let c = try makeWindowInRoot()

        c.newTabForTesting()

        let tab = try XCTUnwrap(spawned.last)
        XCTAssertEqual(tab.lastConfig?.workingDirectory, ShellLaunch.defaultCWD)
    }

    func test_newTab_inheritsTheFocusedCWDWhenOptedIn() throws {
        let c = try makeWindowInRoot()
        inheritCWD(true)

        c.newTabForTesting()

        let tab = try XCTUnwrap(spawned.last)
        XCTAssertEqual(tab.lastConfig?.workingDirectory, root)
    }

    /// A split is a second view of the pane in front of you, so it inherits whatever the key says.
    func test_split_inheritsTheCWDRegardlessOfTheKey() throws {
        let c = try makeWindowInRoot()

        c.handle(.splitVertical)

        let pane = try XCTUnwrap(spawned.last)
        XCTAssertEqual(pane.lastConfig?.workingDirectory, root)
    }

    /// ⌘N reads the same rule through the same function, so the two chords cannot drift. Covered here
    /// rather than through `AppDelegate.route`, which resolves its window from `NSApp.keyWindow` and
    /// has no key window to find in a test run.
    func test_newSessionCWD_isTheOneRuleBothChordsRead() {
        XCTAssertNil(ShellLaunch.newSessionCWD(focused: root), "home by default, whatever is focused")

        inheritCWD(true)
        XCTAssertEqual(ShellLaunch.newSessionCWD(focused: root), root)
        XCTAssertNil(ShellLaunch.newSessionCWD(focused: nil), "an unresolvable pane still means home")
    }
}
