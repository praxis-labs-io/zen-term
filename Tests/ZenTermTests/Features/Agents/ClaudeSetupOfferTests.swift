import AppKit
import TerminalKit
import XCTest

@testable import AgentSetup
@testable import ZenTerm

final class ClaudeSetupOfferTests: WindowTestCase {
    private static let offerTitle = "Teach Claude Code to use zen?"
    private static let updateTitle = "Update zen for Claude Code?"
    private static let updatedTitle = "Updated zen for Claude Code"
    private let files = ClaudeSetupFiles(
        skill: Data("skill".utf8), hook: Data("hook".utf8),
        shippedDigests: [
            ClaudeSetupFiles.digest(of: Data("older".utf8)), ClaudeSetupFiles.digest(of: Data("hook".utf8)),
        ])
    private let edited = Data("my own skill".utf8)
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

    private func makeWindow(offer: SetupOffer<ClaudeCodeSetup>) -> WindowController {
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
        toast(titled: Self.offerTitle, in: c)
    }

    private func toast(titled title: String, in c: WindowController) -> ToastView? {
        guard let content = c.window.contentView else { return nil }
        return descendants(of: content).compactMap { $0 as? ToastView }.first {
            !$0.isDismissing && descendants(of: $0).contains { ($0 as? NSTextField)?.stringValue == title }
        }
    }

    private func install(skill: Data) throws {
        let setup = ClaudeSetup(configRoot: try claudeRoot(), files: files)
        _ = try setup.install()
        try skill.write(to: setup.skillURL)
    }

    private func installedSkill() throws -> Data {
        try Data(contentsOf: ClaudeSetup(configRoot: try claudeRoot(), files: files).skillURL)
    }

    private func state() throws -> ClaudeSetup.State {
        try ClaudeSetup(configRoot: try claudeRoot(), files: files).state()
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
        let c = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))

        try start("claude", in: c)

        waitUntil(offerToast(in: c) != nil, "the setup offer")
    }

    func test_claudeTypedAtAShellPromptOffersIt() throws {
        let c = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))
        let surface = try surface(in: c)

        surface.delegate?.surface(surface, titleDidChange: "\u{2733} Claude Code")

        waitUntil(offerToast(in: c) != nil, "the setup offer")
    }

    func test_anotherAgentStartingOffersNothing() throws {
        let c = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))

        try start("codex", in: c)
        settle()

        XCTAssertNil(offerToast(in: c))
    }

    func test_itOffersOnceALaunchAcrossWindows() throws {
        let offer = SetupOffer<ClaudeCodeSetup>(defaults: defaults)
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
        let first = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))
        try start("claude", in: first)
        waitUntil(offerToast(in: first) != nil, "the setup offer")
        let close = try XCTUnwrap(
            descendants(of: try XCTUnwrap(offerToast(in: first))).compactMap { $0 as? IconButton }.first {
                $0.accessibilityLabel() == "Dismiss"
            })
        close.onClick()

        let later = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))
        try start("claude", in: later)

        waitUntil(offerToast(in: later) != nil, "the setup offer on a later launch")
        XCTAssertFalse(defaults.bool(forKey: SetupOffer<ClaudeCodeSetup>.declinedKey))
    }

    func test_dontAskAgainStopsItForGood() throws {
        let first = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))
        try start("claude", in: first)
        waitUntil(offerToast(in: first) != nil, "the setup offer")
        try press("Don't ask again", on: try XCTUnwrap(offerToast(in: first)))

        let later = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))
        try start("claude", in: later)
        settle()

        XCTAssertNil(offerToast(in: later))
        XCTAssertTrue(defaults.bool(forKey: SetupOffer<ClaudeCodeSetup>.declinedKey))
    }

    func test_anInstalledSetupIsNeverOffered() throws {
        _ = try ClaudeSetup(configRoot: try claudeRoot(), files: files).install()
        let c = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))

        try start("claude", in: c)
        settle()

        XCTAssertNil(offerToast(in: c))
    }

    func test_anOlderShippedSetupIsUpdatedInPlace() throws {
        try install(skill: Data("older".utf8))
        let c = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))

        try start("claude", in: c)

        waitUntil(toast(titled: Self.updatedTitle, in: c) != nil, "the update notice")
        XCTAssertEqual(try state(), .current)
        XCTAssertNil(toast(titled: Self.updateTitle, in: c))
    }

    func test_anInstallDeclinedEarlierStillUpdatesWhatIsInstalled() throws {
        defaults.set(true, forKey: SetupOffer<ClaudeCodeSetup>.declinedKey)
        try install(skill: Data("older".utf8))
        let c = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))

        try start("claude", in: c)

        waitUntil(toast(titled: Self.updatedTitle, in: c) != nil, "the update notice")
        XCTAssertEqual(try state(), .current)
    }

    func test_anUpdateThatCannotWriteSaysWhy() throws {
        try install(skill: Data("older".utf8))
        let folder = try claudeRoot().appendingPathComponent("skills/zen")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let c = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))

        try start("claude", in: c)

        waitUntil(toastTexts(in: c).contains(WindowController.claudeUpdateFailedTitle), "the failure")
        XCTAssertNil(toast(titled: Self.updatedTitle, in: c))
        XCTAssertEqual(try installedSkill(), Data("older".utf8))
    }

    func test_anEditedSetupIsOfferedAndLeftAsItIs() throws {
        try install(skill: edited)
        let c = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))

        try start("claude", in: c)

        waitUntil(toast(titled: Self.updateTitle, in: c) != nil, "the update offer")
        XCTAssertTrue(toastTexts(in: c).contains(WindowController.claudeUpdateOfferMessage))
        XCTAssertEqual(try installedSkill(), edited)
    }

    func test_anEditedSetupIsNotOfferedOnceSetupWasDeclined() throws {
        defaults.set(true, forKey: SetupOffer<ClaudeCodeSetup>.declinedKey)
        try install(skill: edited)
        let c = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))

        try start("claude", in: c)
        settle()

        XCTAssertNil(toast(titled: Self.updateTitle, in: c))
        XCTAssertEqual(try installedSkill(), edited)
    }

    func test_updateReplacesAnEditedSetup() throws {
        try install(skill: edited)
        let c = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))
        try start("claude", in: c)
        waitUntil(toast(titled: Self.updateTitle, in: c) != nil, "the update offer")

        try press("Update", on: try XCTUnwrap(toast(titled: Self.updateTitle, in: c)))

        waitUntil(toast(titled: Self.updatedTitle, in: c) != nil, "the update confirmation")
        XCTAssertFalse(toastTexts(in: c).contains("Claude Code can use zen"))
        XCTAssertEqual(try state(), .current)
    }

    func test_aSetupALaterBuildInstalledIsLeftQuietly() throws {
        let later = ClaudeSetupFiles(skill: Data("later skill".utf8), hook: files.hook, build: 20)
        _ = try ClaudeSetup(configRoot: try claudeRoot(), files: later).install()
        ClaudeCodeSetup.filesOverrideForTesting = ClaudeSetupFiles(
            skill: files.skill, hook: files.hook, shippedDigests: files.shippedDigests, build: 10)
        let c = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))

        try start("claude", in: c)
        settle()

        XCTAssertNil(toast(titled: Self.updateTitle, in: c))
        XCTAssertNil(toast(titled: Self.updatedTitle, in: c))
        XCTAssertEqual(try installedSkill(), later.skill)
    }

    func test_skipThisVersionStopsTheOfferUntilTheFilesChange() throws {
        try install(skill: edited)
        let first = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))
        try start("claude", in: first)
        waitUntil(toast(titled: Self.updateTitle, in: first) != nil, "the update offer")
        try press("Skip this version", on: try XCTUnwrap(toast(titled: Self.updateTitle, in: first)))

        let later = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))
        try start("claude", in: later)
        settle()
        XCTAssertNil(toast(titled: Self.updateTitle, in: later))
        XCTAssertEqual(try installedSkill(), edited)

        ClaudeCodeSetup.filesOverrideForTesting = ClaudeSetupFiles(
            skill: Data("newer skill".utf8), hook: files.hook, shippedDigests: files.shippedDigests)
        let newerBuild = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))
        try start("claude", in: newerBuild)
        waitUntil(toast(titled: Self.updateTitle, in: newerBuild) != nil, "the offer for a newer build")
        XCTAssertEqual(try installedSkill(), edited)
    }

    func test_setUpInstallsAndConfirms() throws {
        let c = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))
        try start("claude", in: c)
        waitUntil(offerToast(in: c) != nil, "the setup offer")

        try press("Set up", on: try XCTUnwrap(offerToast(in: c)))

        waitUntil(toastTexts(in: c).contains("Claude Code can use zen"), "the confirmation")
        XCTAssertEqual(try ClaudeSetup(configRoot: try claudeRoot(), files: files).state(), .current)
    }

    func test_theOfferNamesTheFolderItInstallsTo() throws {
        let c = makeWindow(offer: SetupOffer<ClaudeCodeSetup>(defaults: defaults))

        try start("claude", in: c)

        waitUntil(offerToast(in: c) != nil, "the setup offer")
        let folder = PathDisplay.abbreviatingHome(try claudeRoot().path)
        XCTAssertTrue(
            toastTexts(in: c).contains(WindowController.claudeSetupOfferMessage(in: folder)), "\(toastTexts(in: c))")
    }

    func test_offerCopyFitsTheToast() {
        let messages = [
            WindowController.claudeSetupOfferMessage(in: "~/.claude"), WindowController.claudeUpdateOfferMessage,
        ]
        for line in messages.flatMap({ $0.split(separator: "\n") }) {
            let width = (String(line) as NSString).size(withAttributes: [.font: ToastView.messageFont]).width
            XCTAssertLessThanOrEqual(width, ToastView.messageMaxWidth, "wraps: \(line)")
        }
        for title in [Self.offerTitle, Self.updateTitle, Self.updatedTitle, WindowController.claudeUpdateFailedTitle] {
            let width = (title as NSString).size(withAttributes: [.font: ToastView.titleFont]).width
            XCTAssertLessThanOrEqual(width, ToastView.titleMaxWidth, "truncates: \(title)")
        }
    }
}
