import XCTest

@testable import ZenTerm

@MainActor
final class ConfigApplierDiagnosticFilterTests: XCTestCase {
    private var tempRoot: URL!
    private var announced: [ToastContent] = []
    private var showing: ToastContent?
    private var carded: [KeybindConflict] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-applier-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        ConfigReset.toBuiltIn()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func seed(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
    }

    private func makeApplier() -> ConfigApplier {
        announced = []
        showing = nil
        carded = []
        return ConfigApplier(
            sinks: ConfigApplier.Sinks(
                setKeymap: { _ in }, reportBackendShadow: {}, applyMotion: { _ in },
                announceDiagnostics: { [unowned self] content, _ in
                    self.announced.append(content)
                    self.showing = content
                    return true
                },
                retractDiagnostics: { [unowned self] in self.showing = nil },
                announceConflicts: { [unowned self] in
                    self.carded = $0
                    return true
                },
                retractConflicts: { [unowned self] in self.carded = [] },
                reapplyUpdateCardTheme: {}, applyAutoCheckSetting: {}, publishTheme: {}))
    }

    func test_aChordConflict_getsACardAndNotTheSharedNotice() throws {
        let applier = makeApplier()
        try seed("float = title:lazygit command:lazygit key:cmd+j\n")

        applier.surfaceConfigNotices()

        XCTAssertEqual(announced, [], "nothing joins the shared list")
        XCTAssertEqual(carded.map(\.loser), [.scrollToSelection])
        XCTAssertFalse(carded[0].isRevertable, "a float's key: has nothing to back out to")
    }

    func test_threeConflicts_getThreeCards() throws {
        let applier = makeApplier()
        try seed(
            """
            float = order:1 title:lazygit command:lazygit key:cmd+j
            float = order:2 title:gitdash command:gd key:cmd+k
            float = order:3 title:nvim command:nvim key:cmd+e
            """)

        applier.surfaceConfigNotices()

        XCTAssertEqual(carded.count, 3, "\(carded)")
    }

    func test_aKeybindLineTakingAChord_offersRevert() throws {
        let applier = makeApplier()
        try seed("keybind = split_vertical=cmd+shift+p\n")

        applier.surfaceConfigNotices()

        XCTAssertEqual(carded.map(\.loser), [.toggleCommandPalette])
        XCTAssertTrue(carded[0].isRevertable)
    }

    func test_theSameConflictTwice_isNotReCarded() throws {
        let applier = makeApplier()
        try seed("keybind = split_vertical=cmd+shift+p\n")
        applier.surfaceConfigNotices()
        carded = []

        applier.surfaceConfigNotices()

        XCTAssertEqual(carded, [], "an unchanged set leaves the cards already up alone")
    }

    func test_resolvingAConflict_retractsItsCard() throws {
        let applier = makeApplier()
        try seed("keybind = split_vertical=cmd+shift+p\n")
        applier.surfaceConfigNotices()
        XCTAssertEqual(carded.count, 1)

        try seed("keybind = split_vertical=cmd+shift+p\nkeybind = toggle_command_palette=none\n")
        applier.surfaceConfigNotices()

        XCTAssertEqual(carded, [], "accepted, so nothing is outstanding")
    }

    func test_aRealProblem_stillAnnounces() throws {
        let applier = makeApplier()
        try seed("keybind = frobnicate=cmd+f\n")

        applier.surfaceConfigNotices()

        XCTAssertEqual(announced.count, 1, "\(announced)")
        XCTAssertTrue(announced[0].message.contains("frobnicate"), announced[0].message)
    }

    func test_aMixedConfig_announcesOnlyTheProblem() throws {
        let applier = makeApplier()
        try seed("float = title:lazygit command:lazygit key:cmd+j\nkeybind = frobnicate=cmd+f\n")

        applier.surfaceConfigNotices()

        XCTAssertEqual(announced.count, 1, "\(announced)")
        XCTAssertTrue(announced[0].message.contains("frobnicate"), announced[0].message)
        XCTAssertFalse(announced[0].message.contains("scroll_to_selection"), announced[0].message)
    }

    func test_fixingTheProblem_retractsEvenWithAnExplanationLeft() throws {
        let applier = makeApplier()
        try seed("float = title:lazygit command:lazygit key:cmd+j\nkeybind = frobnicate=cmd+f\n")
        applier.surfaceConfigNotices()
        XCTAssertNotNil(showing)

        try seed("float = title:lazygit command:lazygit key:cmd+j\n")
        applier.surfaceConfigNotices()

        XCTAssertNil(showing, "the notice has to come down, not linger behind the explanation")
    }
}
