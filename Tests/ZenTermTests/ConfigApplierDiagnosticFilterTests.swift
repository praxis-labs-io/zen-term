import XCTest

@testable import ZenTerm

/// Which config problems share the one notice, and which get a card each (ZEN-368).
///
/// A chord conflict is the one diagnostic a user can answer from the notice itself, so it gets its
/// own card with Accept and Revert. Everything else has nothing to press and keeps sharing a list.
/// Aggregating a conflict into that list would mean one dismissal covering three separate decisions.
///
/// Driven through the real `ConfigApplier` rather than `ConfigDiagnostic.isChordConflict` alone,
/// because the split has to sit ahead of the empty check too: a set of nothing-but-conflicts still
/// has to *retract* an outstanding shared notice, and a filter inside `announcement` would leave a
/// stale warning up instead.
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
                reapplyUpdateCardTheme: {}, applyAutoCheckSetting: {}))
    }

    /// A float on ⌘G, which ZEN-367 made Find Next's default. It gets a card of its own, never a
    /// line in the shared list.
    ///
    /// Driven through `surfaceConfigNotices`, which is what launch calls. Calling the conflict half
    /// directly is what let this ship silent: `apply(_:)` had it, launch did not, and a config with
    /// three conflicts opened to nothing.
    func test_aChordConflict_getsACardAndNotTheSharedNotice() throws {
        let applier = makeApplier()
        try seed("float = title:lazygit command:lazygit key:cmd+g\n")

        applier.surfaceConfigNotices()

        XCTAssertEqual(announced, [], "nothing joins the shared list")
        XCTAssertEqual(carded.map(\.loser), [.findNext])
        XCTAssertFalse(carded[0].isRevertable, "a float's key: has nothing to back out to")
    }

    /// Three lines, three cards. Aggregating would make one Accept settle decisions the user was
    /// asked about once.
    func test_threeConflicts_getThreeCards() throws {
        let applier = makeApplier()
        try seed(
            """
            float = order:1 title:lazygit command:lazygit key:cmd+g
            float = order:2 title:gitdash command:gd key:cmd+shift+g
            float = order:3 title:nvim command:nvim key:cmd+e
            """)

        applier.surfaceConfigNotices()

        XCTAssertEqual(carded.count, 3, "\(carded)")
    }

    /// A `keybind =` line took it, so there is a line to delete and Revert is on offer.
    func test_aKeybindLineTakingAChord_offersRevert() throws {
        let applier = makeApplier()
        try seed("keybind = split_vertical=cmd+p\n")

        applier.surfaceConfigNotices()

        XCTAssertEqual(carded.map(\.loser), [.toggleCommandPalette])
        XCTAssertTrue(carded[0].isRevertable)
    }

    /// Every in-app write reloads, so re-carding an unchanged set would put a card the user just
    /// closed straight back on the next Settings keystroke. A fresh launch is a fresh process,
    /// which is what makes an unanswered conflict come back.
    func test_theSameConflictTwice_isNotReCarded() throws {
        let applier = makeApplier()
        try seed("keybind = split_vertical=cmd+p\n")
        applier.surfaceConfigNotices()
        carded = []

        applier.surfaceConfigNotices()

        XCTAssertEqual(carded, [], "an unchanged set leaves the cards already up alone")
    }

    /// Answering one has to take its card down, or the card would outlive the config it describes.
    func test_resolvingAConflict_retractsItsCard() throws {
        let applier = makeApplier()
        try seed("keybind = split_vertical=cmd+p\n")
        applier.surfaceConfigNotices()
        XCTAssertEqual(carded.count, 1)

        try seed("keybind = split_vertical=cmd+p\nkeybind = toggle_command_palette=none\n")
        applier.surfaceConfigNotices()

        XCTAssertEqual(carded, [], "accepted, so nothing is outstanding")
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

        applier.surfaceConfigNotices()

        XCTAssertEqual(announced.count, 1, "\(announced)")
        XCTAssertTrue(announced[0].message.contains("frobnicate"), announced[0].message)
    }

    /// A mixed config announces the problem alone. Counting the explanation would put "2 problems"
    /// on a card that then lists one, and the user would go looking for a second thing to fix.
    func test_aMixedConfig_announcesOnlyTheProblem() throws {
        let applier = makeApplier()
        try seed("float = title:lazygit command:lazygit key:cmd+g\nkeybind = frobnicate=cmd+f\n")

        applier.surfaceConfigNotices()

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
        applier.surfaceConfigNotices()
        XCTAssertNotNil(showing)

        try seed("float = title:lazygit command:lazygit key:cmd+g\n")
        applier.surfaceConfigNotices()

        XCTAssertNil(showing, "the notice has to come down, not linger behind the explanation")
    }
}
