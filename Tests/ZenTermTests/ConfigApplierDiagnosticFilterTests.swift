import XCTest

@testable import ZenTerm

/// Which config problems reach a launch notice, and which explain themselves in place (ZEN-368).
///
/// A chord one of your own config lines took off an action used to toast at every launch. Nothing
/// could clear it: the state is re-derived from the file on every load, so the notice was permanent
/// and named nothing to do. It is not a problem, it is the config working, and the Shortcuts row
/// says so where someone would go looking.
///
/// Driven through the real `ConfigApplier` rather than `ConfigDiagnostic.isProblem` alone, because
/// the filter has to sit ahead of the empty check too: a set of nothing-but-explanations has to
/// *retract* an outstanding notice, and a naive `filter` inside `announcement` would leave a stale
/// warning up instead.
@MainActor
final class ConfigApplierDiagnosticFilterTests: XCTestCase {
    private var tempRoot: URL!
    private var announced: [ToastContent] = []
    private var showing: ToastContent?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-applier-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
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
        return ConfigApplier(
            sinks: ConfigApplier.Sinks(
                setKeymap: { _ in }, reportBackendShadow: {}, applyMotion: { _ in },
                announceDiagnostics: { [unowned self] content, _ in
                    self.announced.append(content)
                    self.showing = content
                    return true
                },
                retractDiagnostics: { [unowned self] in self.showing = nil },
                reapplyUpdateCardTheme: {}, applyAutoCheckSetting: {}))
    }

    /// Drew's config, in miniature: a float on ⌘G, which ZEN-367 made Find Next's default. Three
    /// launches in a row used to mean three identical warnings about a line he wrote on purpose.
    func test_aFloatTakingADefaultChord_announcesNothing() throws {
        let applier = makeApplier()
        try seed("float = title:lazygit command:lazygit key:cmd+g\n")

        applier.surfaceConfigDiagnostics()

        XCTAssertFalse(
            GeneralConfig.current.configDiagnostics.isEmpty,
            "the fact is still collected — the Shortcuts row renders it")
        XCTAssertEqual(announced, [], "it just never becomes a notice")
    }

    /// The problems that are problems still speak up, or the filter would have taken the whole
    /// feature down with it. A line that names no action is dead and has no row to explain itself
    /// on, so a notice is the only place the user could ever learn of it.
    ///
    /// An unparseable line rather than a menu-owned chord or an untypeable one: `MenuShortcuts` reads
    /// the real menu bar and `canType` reads the real layout, and neither exists under `swift test`,
    /// so both would quietly produce no diagnostic and this would pass by testing nothing.
    func test_aRealProblem_stillAnnounces() throws {
        let applier = makeApplier()
        try seed("keybind = frobnicate=cmd+f\n")

        applier.surfaceConfigDiagnostics()

        XCTAssertEqual(announced.count, 1, "\(announced)")
        XCTAssertTrue(announced[0].message.contains("frobnicate"), announced[0].message)
    }

    /// A mixed config announces the problem alone. Counting the explanation would put "2 problems"
    /// on a card that then lists one, and the user would go looking for a second thing to fix.
    func test_aMixedConfig_announcesOnlyTheProblem() throws {
        let applier = makeApplier()
        try seed("float = title:lazygit command:lazygit key:cmd+g\nkeybind = frobnicate=cmd+f\n")

        applier.surfaceConfigDiagnostics()

        XCTAssertEqual(announced.count, 1, "\(announced)")
        XCTAssertTrue(announced[0].message.contains("frobnicate"), announced[0].message)
        XCTAssertFalse(announced[0].message.contains("find_next"), announced[0].message)
    }

    /// The retraction path, which is why the filter sits ahead of the empty check rather than inside
    /// `announcement`. Fix the real problem and leave the float alone: the remaining set is nothing
    /// but explanations, and a notice that stays up would be describing a config that no longer
    /// exists.
    func test_fixingTheProblem_retractsEvenWithAnExplanationLeft() throws {
        let applier = makeApplier()
        try seed("float = title:lazygit command:lazygit key:cmd+g\nkeybind = frobnicate=cmd+f\n")
        applier.surfaceConfigDiagnostics()
        XCTAssertNotNil(showing)

        try seed("float = title:lazygit command:lazygit key:cmd+g\n")
        applier.surfaceConfigDiagnostics()

        XCTAssertNil(showing, "the notice has to come down, not linger behind the explanation")
    }
}
