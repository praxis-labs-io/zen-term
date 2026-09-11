import AppKit
import XCTest

@testable import ZenTerm

/// The CARRY control: a multi-select over what git ignores in the workspace folder. Driven through
/// the real dropdown in a real window; the git probe runs through an injectable seam, so these
/// assert the load / render / toggle wiring without standing up a repo per case
/// (`WorktreeCarryTests` covers what git actually reports).
final class CarryPickerTests: WindowTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/carry-picker-fixture", isDirectory: true)
    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func picker(ignoring ignored: [String]?) -> CarryPicker {
        picker(catalog: ignored.map { IgnoredCatalog(entries: $0, resting: $0, fileCounts: [:], directories: []) })
    }

    private func picker(catalog: IgnoredCatalog?) -> CarryPicker {
        let picker = CarryPicker()
        picker.settle = 0
        picker.probe = { _, _ in catalog }
        picker.translatesAutoresizingMaskIntoConstraints = true
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(picker)
        picker.frame = NSRect(x: 20, y: 320, width: 300, height: 30)
        window = win
        return picker
    }

    /// One `onChanged` per catalog landing, so a test waits on the load rather than sleeping.
    private func load(_ picker: CarryPicker) {
        let landed = expectation(description: "catalog")
        picker.onChanged = { landed.fulfill() }
        picker.workspaceFolder = folder
        wait(for: [landed], timeout: 2)
        picker.onChanged = nil
        window?.layoutIfNeeded()
    }

    /// Open the list, walk down to `index`, and toggle it — the keys a user actually presses.
    private func toggle(_ list: CheckboxDropdown, row index: Int) {
        window?.makeFirstResponder(list)
        press(list, " ", code: 49)
        for _ in 0..<index { press(list, "", code: 125) }
        press(list, " ", code: 49)
    }

    private func press(_ list: CheckboxDropdown, _ chars: String, code: UInt16) {
        list.keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code)!)
    }

    func test_beforeAFolderIsChosen_itSaysSoRatherThanShowingAnEmptyList() {
        let picker = picker(ignoring: [])
        XCTAssertEqual(picker.statusForTesting, "Choose a folder first.")
        XCTAssertNil(picker.focusStop, "there is no stop to arrow to while there is no list")
    }

    func test_theCatalogIsWhatGitIgnores() {
        let picker = picker(ignoring: ["node_modules", ".env"])
        load(picker)

        XCTAssertEqual(picker.catalog, ["node_modules", ".env"])
        XCTAssertEqual(
            picker.dropdownForTesting?.itemsForTesting.map(\.title), ["node_modules", ".env"])
        XCTAssertNil(picker.statusForTesting)
        XCTAssertNotNil(picker.focusStop)
    }

    func test_nothingIsChosenUntilItIsPicked() {
        let picker = picker(ignoring: ["node_modules", ".env"])
        load(picker)

        XCTAssertEqual(picker.carried, [])
        XCTAssertEqual(picker.dropdownForTesting?.buttonTitleForTesting, "Nothing chosen")
    }

    func test_pickingAnEntry_carriesItAndCountsIt() throws {
        let picker = picker(ignoring: ["node_modules", ".env"])
        load(picker)
        let list = try XCTUnwrap(picker.dropdownForTesting)

        toggle(list, row: 1)

        XCTAssertEqual(picker.carried, [".env"])
        XCTAssertEqual(list.buttonTitleForTesting, "1 file")
        XCTAssertEqual(list.itemsForTesting.map(\.isChecked), [false, true])
    }

    func test_pickingACarriedEntry_dropsIt() throws {
        let picker = picker(ignoring: ["node_modules", ".env"])
        picker.setCarried([".env"])
        load(picker)
        let list = try XCTUnwrap(picker.dropdownForTesting)

        toggle(list, row: 1)

        XCTAssertEqual(picker.carried, [])
        XCTAssertEqual(list.buttonTitleForTesting, "Nothing chosen")
    }

    /// The list stays open across a pick, because carrying is several picks per visit.
    func test_theListStaysOpenAcrossAPick() throws {
        let picker = picker(ignoring: ["node_modules", ".env"])
        load(picker)
        let list = try XCTUnwrap(picker.dropdownForTesting)

        toggle(list, row: 0)

        XCTAssertTrue(list.isPopoverOpen)
    }

    /// A `carry` line naming something not on disk is legal: a section covers a repo before and
    /// after its first install. Dropping it from the catalog would delete it on the next save.
    func test_anEntryGitNoLongerIgnores_staysInTheListAndStaysCarried() {
        let picker = picker(ignoring: ["node_modules"])
        picker.setCarried([".env"])
        load(picker)

        XCTAssertEqual(picker.catalog, ["node_modules", ".env"])
        XCTAssertEqual(picker.carried, [".env"])
        XCTAssertEqual(picker.dropdownForTesting?.itemsForTesting.map(\.isChecked), [false, true])
    }

    func test_carriedReadsBackInCatalogOrder() throws {
        let picker = picker(ignoring: ["a", "b", "c"])
        picker.setCarried(["c", "a"])
        load(picker)

        XCTAssertEqual(picker.carried, ["c", "a"], "the authored order survives an untouched load")

        toggle(try XCTUnwrap(picker.dropdownForTesting), row: 1)

        XCTAssertEqual(picker.carried, ["a", "b", "c"], "a pick re-seats the set in catalog order")
    }

    /// Opening the form on a workspace that already carries something used to build a list from the
    /// seeded entries, then tear it down when git answered. Anyone reading it watched it vanish.
    func test_whileTheProbeIsInFlight_thereIsNoListToTearDown() {
        let picker = picker(ignoring: ["node_modules", ".env"])
        picker.settle = 10  // never lands during this test

        picker.setCarried([".env"])
        picker.workspaceFolder = folder

        XCTAssertTrue(picker.isLoadingForTesting)
        XCTAssertEqual(picker.statusForTesting, "Reading what git ignores…")
        XCTAssertNil(picker.focusStop, "nothing to open, so nothing closes under the user")
    }

    /// A catalog landing on an open list has to wait: rebuilding swaps the control out, and the
    /// open card goes with it mid-pick.
    func test_aCatalogLandingOnAnOpenList_waitsForItToClose() throws {
        let picker = picker(ignoring: ["node_modules", ".env"])
        load(picker)
        let first = try XCTUnwrap(picker.dropdownForTesting)
        window?.makeFirstResponder(first)
        press(first, " ", code: 49)
        XCTAssertTrue(first.isPopoverOpen)

        picker.probe = { _, _ in
            IgnoredCatalog(
                entries: ["node_modules", ".env", "dist"], resting: ["node_modules", ".env", "dist"], fileCounts: [:],
                directories: [])
        }
        let landed = expectation(description: "catalog")
        picker.onChanged = { landed.fulfill() }
        picker.workspaceFolder = folder.appendingPathComponent("elsewhere")
        wait(for: [landed], timeout: 2)

        XCTAssertTrue(first.isPopoverOpen, "the open list survives the catalog landing")
        XCTAssertTrue(picker.dropdownForTesting === first, "and it is still the same control")

        press(first, "", code: 53)  // Esc closes it

        XCTAssertEqual(picker.dropdownForTesting?.itemsForTesting.count, 3, "then it rebuilds")
    }

    /// The catalog expands the folder holding it, so it sits among its siblings instead of being
    /// appended after every other row with its folder nowhere near it.
    func test_anAlreadyChosenChild_sitsInPlaceRatherThanAtTheEnd() {
        let picker = CarryPicker()
        picker.settle = 0
        picker.translatesAutoresizingMaskIntoConstraints = true
        picker.probe = { _, chosen in
            let rows =
                chosen.contains("config/credentials/production.key")
                ? ["config/credentials/development.key", "config/credentials/production.key", "z/last"]
                : ["config/credentials", "z/last"]
            return IgnoredCatalog(entries: rows, resting: rows, fileCounts: [:], directories: [])
        }
        picker.setCarried(["config/credentials/production.key"])
        let landed = expectation(description: "catalog")
        picker.onChanged = { landed.fulfill() }
        picker.workspaceFolder = folder
        wait(for: [landed], timeout: 2)

        XCTAssertEqual(
            picker.catalog,
            ["config/credentials/development.key", "config/credentials/production.key", "z/last"])
        XCTAssertFalse(picker.catalog.contains("config/credentials"), "the folded row is gone")
    }

    /// The fold is the resting view, not a wall. Without this there is no way to pick one file out
    /// of a folded folder: the only thing that expands one is already having chosen something in it.
    func test_aFileInsideAFoldedFolder_isReachableByTyping() throws {
        let picker = picker(
            catalog: IgnoredCatalog(
                entries: ["log", "log/one.log", "log/two.log", ".env"],
                resting: ["log", ".env"], fileCounts: ["log": 2], directories: []))
        load(picker)
        let list = try XCTUnwrap(picker.dropdownForTesting)
        window?.makeFirstResponder(list)
        press(list, " ", code: 49)

        XCTAssertEqual(list.visibleIndicesForTesting, [0, 3], "at rest, the folder stands in")

        press(list, "t", code: 17)
        press(list, "w", code: 13)
        press(list, "o", code: 31)

        let shown = list.visibleIndicesForTesting.map { list.itemsForTesting[$0].title }
        XCTAssertTrue(shown.contains("log/two.log"), "a query reaches inside the fold: \(shown)")
    }

    /// Picked out of a folded folder, it has to keep showing: falling back behind the fold on the
    /// next open would read as the pick not having landed.
    func test_aFilePickedOutOfAFold_staysVisibleAtRest() throws {
        let picker = picker(
            catalog: IgnoredCatalog(
                entries: ["log", "log/one.log", "log/two.log", ".env"],
                resting: ["log", ".env"], fileCounts: ["log": 2], directories: []))
        picker.setCarried(["log/two.log"])
        load(picker)
        let list = try XCTUnwrap(picker.dropdownForTesting)
        window?.makeFirstResponder(list)
        press(list, " ", code: 49)

        let shown = list.visibleIndicesForTesting.map { list.itemsForTesting[$0].title }
        XCTAssertEqual(shown, ["log", "log/two.log", ".env"])
    }

    /// The row has to say it stands for more than itself, or the fold is invisible.
    func test_aFoldedFolder_saysHowManyFilesItStandsFor() throws {
        let picker = picker(
            catalog: IgnoredCatalog(
                entries: ["log", "log/one.log", "log/two.log"],
                resting: ["log"], fileCounts: ["log": 2], directories: []))
        load(picker)

        let items = try XCTUnwrap(picker.dropdownForTesting).itemsForTesting
        XCTAssertEqual(items.first { $0.title == "log" }?.note, "2 files")
        XCTAssertNil(items.first { $0.title == "log/one.log" }?.note)
    }

    /// A path alone does not say whether ticking it brings one file or a tree.
    func test_foldersAndFiles_carryDifferentIcons() throws {
        let picker = picker(
            catalog: IgnoredCatalog(
                entries: ["node_modules", ".env"], resting: ["node_modules", ".env"],
                fileCounts: [:], directories: ["node_modules"]))
        load(picker)

        let items = try XCTUnwrap(picker.dropdownForTesting).itemsForTesting
        XCTAssertEqual(items.first { $0.title == "node_modules" }?.symbol, "folder")
        XCTAssertEqual(items.first { $0.title == ".env" }?.symbol, "doc")
    }

    /// A bare line of text read as the control having failed to render. It is select-shaped in
    /// every state, and spins only while git is being asked.
    func test_whileLoading_theControlIsASelectWithASpinner() {
        let picker = picker(ignoring: ["node_modules"])
        picker.settle = 10  // never lands during this test

        picker.workspaceFolder = folder

        XCTAssertEqual(picker.statusForTesting, "Reading what git ignores…")
        XCTAssertTrue(picker.isSpinningForTesting)
    }

    func test_aStateThatIsNotLoading_doesNotSpin() {
        let picker = picker(ignoring: [])
        load(picker)

        XCTAssertEqual(picker.statusForTesting, "Git ignores nothing here yet.")
        XCTAssertFalse(picker.isSpinningForTesting)
    }

    /// A count says how many, never which, so the only way to see the selection was to open the
    /// list and scroll all of it. The line under the select carries the names instead, in full:
    /// these are paths, and no button-width summary holds one.
    func test_theLineUnderTheSelect_listsWhatIsChosen() throws {
        let picker = picker(ignoring: ["apps/rails/node_modules", ".env"])
        load(picker)

        XCTAssertEqual(picker.detailForTesting, CarryPicker.captionText, "the caption until then")

        picker.setCarried([".env", "apps/rails/node_modules"])

        XCTAssertEqual(picker.detailForTesting, ".env\napps/rails/node_modules")
        XCTAssertEqual(picker.summaryForTesting, "2 files", "the button stays a count")

        picker.setCarried([])

        XCTAssertEqual(picker.detailForTesting, CarryPicker.captionText, "and the caption returns")
    }

    /// Ticking a row has to move the line too, or it only tells the truth on a reopen.
    func test_pickingARow_movesTheLineUnderTheSelect() throws {
        let picker = picker(ignoring: ["node_modules", ".env"])
        load(picker)

        toggle(try XCTUnwrap(picker.dropdownForTesting), row: 1)

        XCTAssertEqual(picker.detailForTesting, ".env")
    }

    func test_theCaption_saysWhatTheControlIsFor() {
        XCTAssertTrue(CarryPicker.captionText.lowercased().contains("git ignores"))
        XCTAssertFalse(CarryPicker.captionText.contains("—"), "no em-dashes")
    }

    /// Nil is not "nothing ignored". An empty list there would read as a repo with nothing to carry.
    func test_aFolderGitCannotAnswerFor_saysSo() {
        let picker = picker(ignoring: nil)
        load(picker)

        XCTAssertEqual(picker.statusForTesting, "This folder isn't a git repo.")
        XCTAssertNil(picker.focusStop)
    }

    func test_aRepoThatIgnoresNothing_saysSo() {
        let picker = picker(ignoring: [])
        load(picker)

        XCTAssertEqual(picker.statusForTesting, "Git ignores nothing here yet.")
    }

    /// The reload is coalesced, so walking a path in the folder field costs one `git status`
    /// rather than one per character typed.
    func test_walkingAPath_asksGitOnce() {
        let picker = picker(ignoring: [])
        picker.settle = 0.05
        var asked: [String] = []
        picker.probe = { folder, _ in
            asked.append(folder.path)
            return IgnoredCatalog(entries: [], resting: [], fileCounts: [:], directories: [])
        }
        let landed = expectation(description: "catalog")
        picker.onChanged = { landed.fulfill() }

        for name in ["U", "Us", "User", "Users"] {
            picker.workspaceFolder = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
        }
        wait(for: [landed], timeout: 2)

        XCTAssertEqual(asked, ["/tmp/Users"], "only the path that settled is asked about")
    }
}
