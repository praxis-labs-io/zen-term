import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// ZEN-280: an open modal card paints above the toast stack, and a tool float still paints below it.
///
/// A card owns the keyboard and dims the tile behind it, so a passive notice landing on top of it read
/// as broken. A float is the opposite case on purpose: the ⌘W guard toast ("Close btop first, then
/// ⌘W") fires while a float is open and is telling you to close that float, so it has to stay readable.
///
/// Z-order is not provable from "is it mounted": both views are in the tree either way. These compare
/// sibling-index paths from the window's content view and order them lexicographically, which is what
/// paint order actually is across differing depths.
@MainActor
final class ModalZOrderTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var originalReduceMotion: (() -> Bool)!
    private var controller: WindowController?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        originalReduceMotion = Motion.isReduceMotionEnabled
        // Instant present/dismiss, so a card is mounted by the time the assertion reads the tree.
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        Motion.isReduceMotionEnabled = originalReduceMotion
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
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

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Where `view` sits in paint order, as its chain of sibling indexes from `root`. A later path
    /// (lexicographically) paints on top, whatever depth each view is at.
    private func paintPath(of view: NSView, from root: NSView) -> [Int]? {
        guard view !== root else { return [] }
        guard let parent = view.superview, let above = paintPath(of: parent, from: root),
            let index = parent.subviews.firstIndex(of: view)
        else { return nil }
        return above + [index]
    }

    private func paintsAbove(_ front: NSView, _ back: NSView, in root: NSView) throws -> Bool {
        let frontPath = try XCTUnwrap(paintPath(of: front, from: root), "front view is not in the tree")
        let backPath = try XCTUnwrap(paintPath(of: back, from: root), "back view is not in the tree")
        return frontPath.lexicographicallyPrecedes(backPath) == false && frontPath != backPath
    }

    private func toastStack(in c: WindowController) throws -> NSView {
        let content = try XCTUnwrap(c.window.contentView)
        let toast = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? ToastView }.first, "no toast is mounted")
        return try XCTUnwrap(toast.superview, "the toast has no stack")
    }

    private func openCard(in c: WindowController) throws -> NSView {
        c.handle(.openSettings)
        let content = try XCTUnwrap(c.window.contentView)
        return try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? ModalOverlay }.first, "no card is mounted")
    }

    // MARK: a card over the toasts

    func test_aToastFiredWhileACardIsOpen_paintsBelowIt() throws {
        let c = makeWindow()
        let card = try openCard(in: c)

        c.showToast(ToastContent(variant: .info, title: "notice", message: "body"))

        let stack = try toastStack(in: c)
        let content = try XCTUnwrap(c.window.contentView)
        XCTAssertTrue(
            try paintsAbove(card, stack, in: content),
            "a passive notice must not cover the card that owns the keyboard")
    }

    /// The other order: the stack already exists, then the card opens. This is the common one, and the
    /// one a plain `addSubview` gets right on its own.
    func test_aCardOpenedOverALiveToastStack_paintsAboveIt() throws {
        let c = makeWindow()
        c.showToast(ToastContent(variant: .info, title: "notice", message: "body"))
        let stack = try toastStack(in: c)

        let card = try openCard(in: c)

        let content = try XCTUnwrap(c.window.contentView)
        XCTAssertTrue(try paintsAbove(card, stack, in: content), "the card opens on top of the notice")
    }

    // MARK: a float still under them

    func test_aToolFloatStaysBelowTheToastStack() throws {
        let c = makeWindow()
        c.showToast(ToastContent(variant: .info, title: "notice", message: "body"))
        let stack = try toastStack(in: c)
        let content = try XCTUnwrap(c.window.contentView)

        c.floatsForTesting.toggle(
            ToolFloat(
                id: "probe", order: 0, title: "Probe", icon: ToolFloatParser.defaultIcon, command: "true",
                dir: nil, widthFraction: 0.6, heightFraction: 0.6, requiresGitRepo: false,
                persist: .ephemeral, toggle: Chord(command: true, shift: true, key: "y")))
        let float = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? SurfaceFloatOverlay }.first,
            "no float is mounted")

        XCTAssertTrue(
            try paintsAbove(stack, float, in: content),
            "the ⌘W guard toast fires while a float is open and has to stay readable")
    }

    // MARK: the geometry the card no longer inherits

    /// Window-hosted, the card owns its own gutter constraints. A live `window-gutter` edit used to
    /// re-inset the tile for free; now it has to reach the card too (ZEN-89's bug class).
    func test_aLiveGutterEdit_reInsetsAnOpenCard() throws {
        let c = makeWindow()
        let card = try openCard(in: c)
        c.window.contentView?.layoutSubtreeIfNeeded()
        let before = card.frame

        var config = GeneralConfig.builtIn
        config.windowGutter = GeneralConfig.builtIn.windowGutter + 24
        GeneralConfig.setCurrentForTesting(config)
        NotificationCenter.default.post(
            name: .configDidChange, object: nil,
            userInfo: [ConfigChange.userInfoKey: ConfigChange.chromeLayout])
        c.window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertLessThan(
            card.frame.width, before.width, "a wider gutter has to shrink the open card with the tile")
    }

    // MARK: the ⌘P route to the tool form (ZEN-286)

    /// Settings was the only way to create a tool float. The palette command opens the same form in
    /// its create state, and closing it must not conjure the Settings card the user never opened.
    func test_newToolCommand_opensTheFormInCreateState_andClosesToNothing() throws {
        let c = makeWindow()
        let content = try XCTUnwrap(c.window.contentView)

        c.handle(.newTool)

        let form = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? ToolFloatFormOverlay }.first,
            "the New Tool command has to open the tool-float form")
        let headers = descendants(of: form).compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(headers.contains("New Tool Float"), "in create state, not editing: \(headers)")

        let cancel = try XCTUnwrap(
            descendants(of: form).compactMap { $0 as? AppButton }.first { $0.title == "Cancel" })
        cancel.onTap()

        XCTAssertTrue(
            descendants(of: content).compactMap { $0 as? SettingsOverlay }.isEmpty,
            "cancelling hands back to where it came from, which from ⌘P is nothing")
        XCTAssertTrue(
            descendants(of: content).compactMap { $0 as? ToolFloatFormOverlay }.isEmpty,
            "and the form itself is gone")
    }
}
