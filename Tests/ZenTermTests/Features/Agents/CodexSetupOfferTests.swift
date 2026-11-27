import AppKit
import TerminalKit
import XCTest

@testable import AgentSetup
@testable import ZenTerm

final class CodexSetupOfferTests: WindowTestCase {
    private static let offerTitle = "Teach Codex to use zen?"
    private static let updateTitle = "Update zen for Codex?"
    private static let updatedTitle = "Updated zen for Codex"
    private let files = CodexSetupFiles(
        skill: Data("skill".utf8), hook: Data("hook".utf8),
        shippedDigests: [
            CodexSetupFiles.digest(of: Data("older".utf8)), CodexSetupFiles.digest(of: Data("hook".utf8)),
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
        CodexAgentSetup.filesOverrideForTesting = files
        suiteName = "zenterm-codex-offer-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        for c in controllers {
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: c.windowID)
        }
        controllers = []
        defaults.removePersistentDomain(forName: suiteName)
        CodexAgentSetup.filesOverrideForTesting = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func makeWindow(offer: SetupOffer<CodexAgentSetup>) -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: FileManager.default.temporaryDirectory
        )
        c.codexSetupOffer = offer
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
        let setup = CodexSetup(configRoot: try codexRoot(), files: files)
        _ = try setup.install()
        try skill.write(to: setup.skillURL)
    }

    private func installedSkill() throws -> Data {
        try Data(contentsOf: CodexSetup(configRoot: try codexRoot(), files: files).skillURL)
    }

    private func state() throws -> CodexSetup.State {
        try CodexSetup(configRoot: try codexRoot(), files: files).state()
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

    private func codexRoot() throws -> URL { try XCTUnwrap(CodexAgentSetup.configRootOverrideForTesting) }

    func test_codexStartingWithoutSetupOffersIt() throws {
        let c = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))

        try start("codex", in: c)

        waitUntil(offerToast(in: c) != nil, "the setup offer")
    }

    func test_codexTypedAtAShellPromptOffersIt() throws {
        let c = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))
        let surface = try surface(in: c)

        surface.delegate?.surface(surface, titleDidChange: "codex")

        waitUntil(offerToast(in: c) != nil, "the setup offer")
    }

    func test_anotherAgentStartingOffersNothing() throws {
        let c = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))

        try start("claude", in: c)
        settle()

        XCTAssertNil(offerToast(in: c))
    }

    func test_itOffersOnceALaunchAcrossWindows() throws {
        let offer = SetupOffer<CodexAgentSetup>(defaults: defaults)
        let first = makeWindow(offer: offer)
        try start("codex", in: first)
        waitUntil(offerToast(in: first) != nil, "the setup offer")
        let toast = try XCTUnwrap(offerToast(in: first))
        toast.onClose?()

        let second = makeWindow(offer: offer)
        try start("codex", in: second)
        settle()

        XCTAssertNil(offerToast(in: second))
    }

    func test_notNowAsksAgainOnALaterLaunch() throws {
        let first = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))
        try start("codex", in: first)
        waitUntil(offerToast(in: first) != nil, "the setup offer")
        let close = try XCTUnwrap(
            descendants(of: try XCTUnwrap(offerToast(in: first))).compactMap { $0 as? IconButton }.first {
                $0.accessibilityLabel() == "Dismiss"
            })
        close.onClick()

        let later = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))
        try start("codex", in: later)

        waitUntil(offerToast(in: later) != nil, "the setup offer on a later launch")
        XCTAssertFalse(defaults.bool(forKey: SetupOffer<CodexAgentSetup>.declinedKey))
    }

    func test_dontAskAgainStopsItForGood() throws {
        let first = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))
        try start("codex", in: first)
        waitUntil(offerToast(in: first) != nil, "the setup offer")
        try press("Don't ask again", on: try XCTUnwrap(offerToast(in: first)))

        let later = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))
        try start("codex", in: later)
        settle()

        XCTAssertNil(offerToast(in: later))
        XCTAssertTrue(defaults.bool(forKey: SetupOffer<CodexAgentSetup>.declinedKey))
    }

    func test_anInstalledSetupIsNeverOffered() throws {
        _ = try CodexSetup(configRoot: try codexRoot(), files: files).install()
        let c = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))

        try start("codex", in: c)
        settle()

        XCTAssertNil(offerToast(in: c))
    }

    func test_anOlderShippedSetupIsUpdatedInPlace() throws {
        try install(skill: Data("older".utf8))
        let c = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))

        try start("codex", in: c)

        waitUntil(toast(titled: Self.updatedTitle, in: c) != nil, "the update notice")
        XCTAssertEqual(try state(), .current)
        XCTAssertNil(toast(titled: Self.updateTitle, in: c))
    }

    func test_anInstallDeclinedEarlierStillUpdatesWhatIsInstalled() throws {
        defaults.set(true, forKey: SetupOffer<CodexAgentSetup>.declinedKey)
        try install(skill: Data("older".utf8))
        let c = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))

        try start("codex", in: c)

        waitUntil(toast(titled: Self.updatedTitle, in: c) != nil, "the update notice")
        XCTAssertEqual(try state(), .current)
    }

    func test_anUpdateThatCannotWriteSaysWhy() throws {
        try install(skill: Data("older".utf8))
        let folder = try codexRoot().appendingPathComponent("skills/zen")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let c = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))

        try start("codex", in: c)

        waitUntil(toastTexts(in: c).contains(WindowController.updateFailedTitle), "the failure")
        XCTAssertNil(toast(titled: Self.updatedTitle, in: c))
        XCTAssertEqual(try installedSkill(), Data("older".utf8))
    }

    func test_anEditedSetupIsOfferedAndLeftAsItIs() throws {
        try install(skill: edited)
        let c = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))

        try start("codex", in: c)

        waitUntil(toast(titled: Self.updateTitle, in: c) != nil, "the update offer")
        XCTAssertTrue(toastTexts(in: c).contains(WindowController.updateOfferMessage))
        XCTAssertEqual(try installedSkill(), edited)
    }

    func test_anEditedSetupIsNotOfferedOnceSetupWasDeclined() throws {
        defaults.set(true, forKey: SetupOffer<CodexAgentSetup>.declinedKey)
        try install(skill: edited)
        let c = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))

        try start("codex", in: c)
        settle()

        XCTAssertNil(toast(titled: Self.updateTitle, in: c))
        XCTAssertEqual(try installedSkill(), edited)
    }

    func test_updateReplacesAnEditedSetup() throws {
        try install(skill: edited)
        let c = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))
        try start("codex", in: c)
        waitUntil(toast(titled: Self.updateTitle, in: c) != nil, "the update offer")

        try press("Update", on: try XCTUnwrap(toast(titled: Self.updateTitle, in: c)))

        waitUntil(toast(titled: Self.updatedTitle, in: c) != nil, "the update confirmation")
        XCTAssertFalse(toastTexts(in: c).contains("Codex can use zen"))
        XCTAssertEqual(try state(), .current)
    }

    func test_aSetupALaterBuildInstalledIsLeftQuietly() throws {
        let later = CodexSetupFiles(skill: Data("later skill".utf8), hook: files.hook, build: 20)
        _ = try CodexSetup(configRoot: try codexRoot(), files: later).install()
        CodexAgentSetup.filesOverrideForTesting = CodexSetupFiles(
            skill: files.skill, hook: files.hook, shippedDigests: files.shippedDigests, build: 10)
        let c = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))

        try start("codex", in: c)
        settle()

        XCTAssertNil(toast(titled: Self.updateTitle, in: c))
        XCTAssertNil(toast(titled: Self.updatedTitle, in: c))
        XCTAssertEqual(try installedSkill(), later.skill)
    }

    func test_skipThisVersionStopsTheOfferUntilTheFilesChange() throws {
        try install(skill: edited)
        let first = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))
        try start("codex", in: first)
        waitUntil(toast(titled: Self.updateTitle, in: first) != nil, "the update offer")
        try press("Skip this version", on: try XCTUnwrap(toast(titled: Self.updateTitle, in: first)))

        let later = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))
        try start("codex", in: later)
        settle()
        XCTAssertNil(toast(titled: Self.updateTitle, in: later))
        XCTAssertEqual(try installedSkill(), edited)

        CodexAgentSetup.filesOverrideForTesting = CodexSetupFiles(
            skill: Data("newer skill".utf8), hook: files.hook, shippedDigests: files.shippedDigests)
        let newerBuild = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))
        try start("codex", in: newerBuild)
        waitUntil(toast(titled: Self.updateTitle, in: newerBuild) != nil, "the offer for a newer build")
        XCTAssertEqual(try installedSkill(), edited)
    }

    func test_setUpInstallsAndConfirms() throws {
        let c = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))
        try start("codex", in: c)
        waitUntil(offerToast(in: c) != nil, "the setup offer")

        try press("Set up", on: try XCTUnwrap(offerToast(in: c)))

        waitUntil(toastTexts(in: c).contains("Codex can use zen"), "the confirmation")
        XCTAssertEqual(try CodexSetup(configRoot: try codexRoot(), files: files).state(), .current)
    }

    func test_theOfferNamesTheFolderItInstallsTo() throws {
        let c = makeWindow(offer: SetupOffer<CodexAgentSetup>(defaults: defaults))

        try start("codex", in: c)

        waitUntil(offerToast(in: c) != nil, "the setup offer")
        let folder = PathDisplay.abbreviatingHome(try codexRoot().path)
        XCTAssertTrue(
            toastTexts(in: c).contains(WindowController.setupOfferMessage(in: folder)), "\(toastTexts(in: c))")
    }

    func test_offerCopyFitsTheToast() {
        let messages = [
            WindowController.setupOfferMessage(in: "~/.codex"), WindowController.updateOfferMessage,
            WindowController.codexSetUpMessage,
        ]
        for line in messages.flatMap({ $0.split(separator: "\n") }) {
            let width = (String(line) as NSString).size(withAttributes: [.font: ToastView.messageFont]).width
            XCTAssertLessThanOrEqual(width, ToastView.messageMaxWidth, "wraps: \(line)")
        }
        for title in [
            Self.offerTitle, Self.updateTitle, Self.updatedTitle, "Codex can use zen", "Couldn't set up Codex",
            WindowController.updateFailedTitle,
        ] {
            let width = (title as NSString).size(withAttributes: [.font: ToastView.titleFont]).width
            XCTAssertLessThanOrEqual(width, ToastView.titleMaxWidth, "truncates: \(title)")
        }
    }
}
