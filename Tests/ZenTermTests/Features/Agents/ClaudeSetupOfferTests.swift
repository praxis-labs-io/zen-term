import AgentSetup
import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ClaudeSetupOfferTests: WindowTestCase {
    private static let offerTitle = "Teach Claude Code to use zen?"
    private let files = ClaudeSetupFiles(skill: Data("skill".utf8), hook: Data("hook".utf8))
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private let originalPresence = WindowController.isPresent
    private var controllers: [WindowController] = []
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        WindowController.isPresent = { _ in true }
        Motion.isReduceMotionEnabled = { true }
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
        ClaudeCodeSetup.filesOverrideForTesting = files
        suiteName = "zenterm-claude-offer-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        for c in controllers {
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: c.windowID)
        }
        controllers = []
        defaults.removePersistentDomain(forName: suiteName)
        ClaudeCodeSetup.filesOverrideForTesting = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func makeWindow(offer: ClaudeSetupOffer) -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: FileManager.default.temporaryDirectory
        )
        c.claudeSetupOffer = offer
        c.mountAndStart()
        c.window.contentView?.layoutSubtreeIfNeeded()
        controllers.append(c)
        return c
    }

    private func surface(in c: WindowController) throws -> RecordingSurface {
        let tab = try XCTUnwrap(c.tabOrderForTesting.first)
        return try XCTUnwrap(c.controllerForTesting(tab: tab)?.allSurfaces.first as? RecordingSurface)
    }

    private func start(_ app: String, in c: WindowController) throws {
        let surface = try surface(in: c)
        surface.delegate?.surface(surface, programStatusDidChange: TerminalProgramStatus(state: .idle, app: app))
    }

    private func offerToast(in c: WindowController) -> ToastView? {
        guard let content = c.window.contentView else { return nil }
        return descendants(of: content).compactMap { $0 as? ToastView }.first {
            !$0.isDismissing && descendants(of: $0).contains { ($0 as? NSTextField)?.stringValue == Self.offerTitle }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    private func press(_ title: String, on toast: ToastView) throws {
        let button = try XCTUnwrap(descendants(of: toast).compactMap { $0 as? AppButton }.first { $0.title == title })
        button.performClick(nil)
    }

    private func claudeRoot() throws -> URL { try XCTUnwrap(ClaudeCodeSetup.configRootOverrideForTesting) }

    func test_claudeStartingWithoutSetupOffersIt() throws {
        let c = makeWindow(offer: ClaudeSetupOffer(defaults: defaults))

        try start("claude", in: c)

        waitUntil(offerToast(in: c) != nil, "the setup offer")
    }

    func test_claudeTypedAtAShellPromptOffersIt() throws {
        let c = makeWindow(offer: ClaudeSetupOffer(defaults: defaults))
        let surface = try surface(in: c)

        surface.delegate?.surface(surface, titleDidChange: "\u{2733} Claude Code")

        waitUntil(offerToast(in: c) != nil, "the setup offer")
    }

    func test_anotherAgentStartingOffersNothing() throws {
        let c = makeWindow(offer: ClaudeSetupOffer(defaults: defaults))

        try start("codex", in: c)
        settle()

        XCTAssertNil(offerToast(in: c))
    }

    func test_itOffersOnceALaunchAcrossWindows() throws {
        let offer = ClaudeSetupOffer(defaults: defaults)
        let first = makeWindow(offer: offer)
        try start("claude", in: first)
        waitUntil(offerToast(in: first) != nil, "the setup offer")
        let toast = try XCTUnwrap(offerToast(in: first))
        toast.onClose?()

        let second = makeWindow(offer: offer)
        try start("claude", in: second)
        settle()

        XCTAssertNil(offerToast(in: second))
    }

    func test_notNowAsksAgainOnALaterLaunch() throws {
        let first = makeWindow(offer: ClaudeSetupOffer(defaults: defaults))
        try start("claude", in: first)
        waitUntil(offerToast(in: first) != nil, "the setup offer")
        let close = try XCTUnwrap(
            descendants(of: try XCTUnwrap(offerToast(in: first))).compactMap { $0 as? IconButton }.first {
                $0.accessibilityLabel() == "Dismiss"
            })
        close.onClick()

        let later = makeWindow(offer: ClaudeSetupOffer(defaults: defaults))
        try start("claude", in: later)

        waitUntil(offerToast(in: later) != nil, "the setup offer on a later launch")
        XCTAssertFalse(defaults.bool(forKey: ClaudeSetupOffer.declinedKey))
    }

    func test_dontAskAgainStopsItForGood() throws {
        let first = makeWindow(offer: ClaudeSetupOffer(defaults: defaults))
        try start("claude", in: first)
        waitUntil(offerToast(in: first) != nil, "the setup offer")
        try press("Don't ask again", on: try XCTUnwrap(offerToast(in: first)))

        let later = makeWindow(offer: ClaudeSetupOffer(defaults: defaults))
        try start("claude", in: later)
        settle()

        XCTAssertNil(offerToast(in: later))
        XCTAssertTrue(defaults.bool(forKey: ClaudeSetupOffer.declinedKey))
    }

    func test_anInstalledSetupIsNeverOffered() throws {
        _ = try ClaudeSetup(configRoot: try claudeRoot(), files: files).install()
        let c = makeWindow(offer: ClaudeSetupOffer(defaults: defaults))

        try start("claude", in: c)
        settle()

        XCTAssertNil(offerToast(in: c))
    }

    func test_anOutdatedSetupIsLeftToSettings() throws {
        let older = ClaudeSetupFiles(skill: Data("older".utf8), hook: files.hook)
        _ = try ClaudeSetup(configRoot: try claudeRoot(), files: older).install()
        let c = makeWindow(offer: ClaudeSetupOffer(defaults: defaults))

        try start("claude", in: c)
        settle()

        XCTAssertNil(offerToast(in: c))
    }

    func test_setUpInstallsAndConfirms() throws {
        let c = makeWindow(offer: ClaudeSetupOffer(defaults: defaults))
        try start("claude", in: c)
        waitUntil(offerToast(in: c) != nil, "the setup offer")

        try press("Set up", on: try XCTUnwrap(offerToast(in: c)))

        waitUntil(toastTexts(in: c).contains("Claude Code can use zen"), "the confirmation")
        XCTAssertEqual(try ClaudeSetup(configRoot: try claudeRoot(), files: files).state(), .current)
    }

    func test_theOfferNamesTheFolderItInstallsTo() throws {
        let c = makeWindow(offer: ClaudeSetupOffer(defaults: defaults))

        try start("claude", in: c)

        waitUntil(offerToast(in: c) != nil, "the setup offer")
        let folder = PathDisplay.abbreviatingHome(try claudeRoot().path)
        XCTAssertTrue(
            toastTexts(in: c).contains(WindowController.claudeSetupOfferMessage(in: folder)), "\(toastTexts(in: c))")
    }

    func test_offerCopyFitsTheToast() {
        for line in WindowController.claudeSetupOfferMessage(in: "~/.claude").split(separator: "\n") {
            let width = (String(line) as NSString).size(withAttributes: [.font: ToastView.messageFont]).width
            XCTAssertLessThanOrEqual(width, ToastView.messageMaxWidth, "wraps: \(line)")
        }
        let titleRoom = ToastView.messageMaxWidth - ChromeMetrics.Height.xs - ChromeMetrics.Spacing.s6
        let title = Self.offerTitle as NSString
        XCTAssertLessThanOrEqual(
            title.size(withAttributes: [.font: ChromeType.font(.body, weight: .semibold)]).width, titleRoom)
    }
}
