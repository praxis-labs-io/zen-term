import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class ModalZOrderTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
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

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

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

    func test_aCardOpenedOverALiveToastStack_paintsAboveIt() throws {
        let c = makeWindow()
        c.showToast(ToastContent(variant: .info, title: "notice", message: "body"))
        let stack = try toastStack(in: c)

        let card = try openCard(in: c)

        let content = try XCTUnwrap(c.window.contentView)
        XCTAssertTrue(try paintsAbove(card, stack, in: content), "the card opens on top of the notice")
    }

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

    func test_theCardsTop_clearsTheWindowButtonsLikeTheTileDoes() throws {
        let c = makeWindow()
        let card = try openCard(in: c)
        c.window.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(c.window.contentView)

        let tile = try XCTUnwrap(c.focusedPanelForTesting, "expected a mounted pane to measure against")
        XCTAssertEqual(
            card.convert(card.bounds, to: content).minY,
            tile.convert(tile.bounds, to: content).minY, accuracy: 1,
            "the card starts where the tile starts, not at the bare gutter")
        XCTAssertGreaterThan(
            ChromeMetrics.topInset, GeneralConfig.current.windowGutter,
            "premise: window-chrome is on, so the tile's top is inset past the buttons")
    }

    func test_reportIssue_isRefusedWhileAConfirmIsWaiting() throws {
        let c = makeWindow()
        var confirmed = 0
        c.presentConfirm(
            variant: .warning, title: "Close 2 panes", message: "This closes both.",
            confirmLabel: "Close", onConfirm: { confirmed += 1 })

        c.openReportIssue()

        let content = try XCTUnwrap(c.window.contentView)
        XCTAssertTrue(
            descendants(of: content).compactMap { $0 as? ReportIssueOverlay }.isEmpty,
            "the confirm has to be answered before a card can cover it")
        XCTAssertTrue(c.isConfirmOpen, "and it is still up, waiting")
        XCTAssertEqual(confirmed, 0)
    }

    func test_newToolFromInsideSettings_handsBackToSettings() throws {
        let c = makeWindow()
        _ = try openCard(in: c)

        c.handle(.newTool)
        let content = try XCTUnwrap(c.window.contentView)
        let form = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? ToolFloatFormOverlay }.first)
        let cancel = try XCTUnwrap(
            descendants(of: form).compactMap { $0 as? AppButton }.first { $0.title == "Cancel" })
        cancel.onTap()

        XCTAssertFalse(
            descendants(of: content).compactMap { $0 as? SettingsOverlay }.isEmpty,
            "cancelling returns to the card the chord closed")
    }
}
