import AppKit
import TerminalKit
import XCTest

@testable import AgentSetup
@testable import ZenTerm

final class PiSetupOfferTests: WindowTestCase {
    private static let offerTitle = "Teach Pi to use zen?"
    private static let updateTitle = "Update zen for Pi?"
    private static let updatedTitle = "Updated zen for Pi"
    private let files = PiSetupFiles(
        skill: Data("skill".utf8), extension: Data("extension".utf8),
        shippedDigests: [
            PiSetupFiles.digest(of: Data("older".utf8)), PiSetupFiles.digest(of: Data("extension".utf8)),
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
        var config = GeneralConfig.builtIn
        config.floats = ["pi", "codex"].enumerated().map { index, program in
            ToolFloat(
                id: program, order: index, title: program, icon: ToolFloatParser.defaultIcon, command: program,
                dir: nil, widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false, persist: .window,
                toggle: Chord(command: true, shift: true, key: index == 0 ? "b" : "j"))
        }
        GeneralConfig.setCurrentForTesting(config)
        PiCodingAgentSetup.filesOverrideForTesting = files
        ClaudeCodeSetup.filesOverrideForTesting = ClaudeSetupFiles(skill: Data("skill".utf8), hook: Data("hook".utf8))
        suiteName = "zenterm-pi-offer-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        for c in controllers {
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: c.windowID)
        }
        controllers = []
        defaults.removePersistentDomain(forName: suiteName)
        PiCodingAgentSetup.filesOverrideForTesting = nil
        ClaudeCodeSetup.filesOverrideForTesting = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func makeWindow(offer: SetupOffer<PiCodingAgentSetup>) -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: FileManager.default.temporaryDirectory
        )
        c.piSetupOffer = offer
        c.claudeSetupOffer = SetupOffer<ClaudeCodeSetup>(defaults: defaults)
        c.mountAndStart()
        c.window.contentView?.layoutSubtreeIfNeeded()
        controllers.append(c)
        return c
    }

    private func newOffer() -> SetupOffer<PiCodingAgentSetup> { SetupOffer<PiCodingAgentSetup>(defaults: defaults) }

    private func launch(_ program: String, in c: WindowController) {
        c.handle(.toggleToolFloat(program))
    }

    private func toast(titled title: String, in c: WindowController) -> ToastView? {
        guard let content = c.window.contentView else { return nil }
        return descendants(of: content).compactMap { $0 as? ToastView }.first {
            !$0.isDismissing && descendants(of: $0).contains { ($0 as? NSTextField)?.stringValue == title }
        }
    }

    private func offerToast(in c: WindowController) -> ToastView? { toast(titled: Self.offerTitle, in: c) }

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

    private func piRoot() throws -> URL { try XCTUnwrap(PiCodingAgentSetup.configRootOverrideForTesting) }

    private func setup(_ files: PiSetupFiles? = nil) throws -> PiSetup {
        PiSetup(configRoot: try piRoot(), files: files ?? self.files)
    }

    private func install(skill: Data) throws {
        let setup = try setup()
        _ = try setup.install()
        try skill.write(to: setup.skillURL)
    }

    private func installedSkill() throws -> Data { try Data(contentsOf: try setup().skillURL) }

    func test_piStartingWithoutSetupOffersIt() throws {
        let c = makeWindow(offer: newOffer())

        launch("pi", in: c)

        waitUntil(offerToast(in: c) != nil, "the setup offer")
        XCTAssertNil(toast(titled: "Teach Claude Code to use zen?", in: c), "Pi's offer is Pi's alone")
    }

    func test_piTypedAtAShellPromptOffersIt() throws {
        let c = makeWindow(offer: newOffer())
        let tab = try XCTUnwrap(c.tabOrderForTesting.first)
        let surface = try XCTUnwrap(c.controllerForTesting(tab: tab)?.allSurfaces.first as? RecordingSurface)

        surface.delegate?.surface(surface, titleDidChange: "π - zen-term")

        waitUntil(offerToast(in: c) != nil, "the setup offer")
        XCTAssertEqual(c.agentNameForTesting(try XCTUnwrap(c.focusedSurfaceIDForTesting)), "pi")
    }

    func test_anotherAgentStartingOffersNothing() throws {
        let c = makeWindow(offer: newOffer())

        launch("codex", in: c)
        settle()

        XCTAssertNil(offerToast(in: c))
    }

    func test_itOffersOnceALaunchAcrossWindows() throws {
        let offer = newOffer()
        let first = makeWindow(offer: offer)
        launch("pi", in: first)
        waitUntil(offerToast(in: first) != nil, "the setup offer")
        try XCTUnwrap(offerToast(in: first)).onClose?()

        let second = makeWindow(offer: offer)
        launch("pi", in: second)
        settle()

        XCTAssertNil(offerToast(in: second))
    }

    func test_dontAskAgainStopsItForGood() throws {
        let first = makeWindow(offer: newOffer())
        launch("pi", in: first)
        waitUntil(offerToast(in: first) != nil, "the setup offer")
        try press("Don't ask again", on: try XCTUnwrap(offerToast(in: first)))

        let later = makeWindow(offer: newOffer())
        launch("pi", in: later)
        settle()

        XCTAssertNil(offerToast(in: later))
        XCTAssertTrue(defaults.bool(forKey: SetupOffer<PiCodingAgentSetup>.declinedKey))
        XCTAssertFalse(defaults.bool(forKey: SetupOffer<ClaudeCodeSetup>.declinedKey))
    }

    func test_anInstalledSetupIsNeverOffered() throws {
        _ = try setup().install()
        let c = makeWindow(offer: newOffer())

        launch("pi", in: c)
        settle()

        XCTAssertNil(offerToast(in: c))
    }

    func test_anOlderShippedSetupIsUpdatedInPlace() throws {
        try install(skill: Data("older".utf8))
        let c = makeWindow(offer: newOffer())

        launch("pi", in: c)

        waitUntil(toast(titled: Self.updatedTitle, in: c) != nil, "the update notice")
        XCTAssertEqual(try setup().state(), .current)
        XCTAssertNil(toast(titled: Self.updateTitle, in: c))
    }

    func test_anEditedSetupIsOfferedAndLeftAsItIs() throws {
        try install(skill: edited)
        let c = makeWindow(offer: newOffer())

        launch("pi", in: c)

        waitUntil(toast(titled: Self.updateTitle, in: c) != nil, "the update offer")
        XCTAssertTrue(toastTexts(in: c).contains(WindowController.updateOfferMessage))
        XCTAssertEqual(try installedSkill(), edited)
    }

    func test_updateReplacesAnEditedSetup() throws {
        try install(skill: edited)
        let c = makeWindow(offer: newOffer())
        launch("pi", in: c)
        waitUntil(toast(titled: Self.updateTitle, in: c) != nil, "the update offer")

        try press("Update", on: try XCTUnwrap(toast(titled: Self.updateTitle, in: c)))

        waitUntil(toast(titled: Self.updatedTitle, in: c) != nil, "the update confirmation")
        XCTAssertEqual(try setup().state(), .current)
    }

    func test_aSetupALaterBuildInstalledIsLeftQuietly() throws {
        let later = PiSetupFiles(skill: Data("later skill".utf8), extension: files.extension, build: 20)
        _ = try setup(later).install()
        PiCodingAgentSetup.filesOverrideForTesting = PiSetupFiles(
            skill: files.skill, extension: files.extension, shippedDigests: files.shippedDigests, build: 10)
        let c = makeWindow(offer: newOffer())

        launch("pi", in: c)
        settle()

        XCTAssertNil(toast(titled: Self.updateTitle, in: c))
        XCTAssertNil(toast(titled: Self.updatedTitle, in: c))
        XCTAssertEqual(try installedSkill(), later.skill)
    }

    func test_skipThisVersionStopsTheOfferUntilTheFilesChange() throws {
        try install(skill: edited)
        let first = makeWindow(offer: newOffer())
        launch("pi", in: first)
        waitUntil(toast(titled: Self.updateTitle, in: first) != nil, "the update offer")
        try press("Skip this version", on: try XCTUnwrap(toast(titled: Self.updateTitle, in: first)))

        let later = makeWindow(offer: newOffer())
        launch("pi", in: later)
        settle()
        XCTAssertNil(toast(titled: Self.updateTitle, in: later))

        PiCodingAgentSetup.filesOverrideForTesting = PiSetupFiles(
            skill: Data("newer skill".utf8), extension: files.extension, shippedDigests: files.shippedDigests)
        let newerBuild = makeWindow(offer: newOffer())
        launch("pi", in: newerBuild)
        waitUntil(toast(titled: Self.updateTitle, in: newerBuild) != nil, "the offer for a newer build")
        XCTAssertEqual(try installedSkill(), edited)
    }

    func test_setUpInstallsAndConfirms() throws {
        let c = makeWindow(offer: newOffer())
        launch("pi", in: c)
        waitUntil(offerToast(in: c) != nil, "the setup offer")

        try press("Set up", on: try XCTUnwrap(offerToast(in: c)))

        waitUntil(toastTexts(in: c).contains("Pi can use zen"), "the confirmation")
        XCTAssertEqual(try setup().state(), .current)
    }

    func test_theOfferNamesTheFolderItInstallsTo() throws {
        let c = makeWindow(offer: newOffer())

        launch("pi", in: c)

        waitUntil(offerToast(in: c) != nil, "the setup offer")
        let folder = PathDisplay.abbreviatingHome(try piRoot().path)
        XCTAssertTrue(
            toastTexts(in: c).contains(WindowController.piSetupOfferMessage(in: folder)), "\(toastTexts(in: c))")
    }

    func test_offerCopyFitsTheToast() {
        for line in WindowController.piSetupOfferMessage(in: "~/.pi/agent").split(separator: "\n") {
            let width = (String(line) as NSString).size(withAttributes: [.font: ToastView.messageFont]).width
            XCTAssertLessThanOrEqual(width, ToastView.messageMaxWidth, "wraps: \(line)")
        }
        for title in [Self.offerTitle, Self.updateTitle, Self.updatedTitle, "Pi can use zen", "Couldn't set up Pi"] {
            let width = (title as NSString).size(withAttributes: [.font: ToastView.titleFont]).width
            XCTAssertLessThanOrEqual(width, ToastView.titleMaxWidth, "truncates: \(title)")
        }
    }
}
