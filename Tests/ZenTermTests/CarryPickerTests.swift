import AppKit
import XCTest

@testable import ZenTerm

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
        picker(catalogProvider: { catalog })
    }

    private func picker(catalogProvider: @escaping () -> IgnoredCatalog?) -> CarryPicker {
        let picker = CarryPicker()
        picker.settle = 0
        picker.probe = { _, _ in catalogProvider() }
        picker.translatesAutoresizingMaskIntoConstraints = true
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(picker)
        picker.frame = NSRect(x: 20, y: 320, width: 300, height: 30)
        window = win
        return picker
    }

    private func load(_ picker: CarryPicker) {
        let landed = expectation(description: "catalog")
        picker.onChanged = { landed.fulfill() }
        picker.workspaceFolder = folder
        wait(for: [landed], timeout: 2)
        picker.onChanged = nil
        window?.layoutIfNeeded()
    }

    private func spin() {
        let settled = expectation(description: "settled")
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.main.async { settled.fulfill() }
        }
        wait(for: [settled], timeout: 2)
    }

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

    func test_theListStaysOpenAcrossAPick() throws {
        let picker = picker(ignoring: ["node_modules", ".env"])
        load(picker)
        let list = try XCTUnwrap(picker.dropdownForTesting)

        toggle(list, row: 0)

        XCTAssertTrue(list.isPopoverOpen)
    }

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

    func test_whileTheProbeIsInFlight_thereIsNoListToTearDown() {
        let picker = picker(ignoring: ["node_modules", ".env"])
        picker.settle = 10

        picker.setCarried([".env"])
        picker.workspaceFolder = folder

        XCTAssertTrue(picker.isLoadingForTesting)
        XCTAssertEqual(picker.statusForTesting, "Reading what git ignores…")
        XCTAssertNil(picker.dropdownForTesting, "no list to close under the user")
    }

    func test_aCatalogLandingOnAnOpenList_changesNothingUntilItCloses() throws {
        var rows = ["aaa", "bbb"]
        let picker = picker(catalogProvider: {
            IgnoredCatalog(entries: rows, resting: rows, fileCounts: [:], directories: [])
        })
        load(picker)
        let list = try XCTUnwrap(picker.dropdownForTesting)
        window?.makeFirstResponder(list)
        press(list, " ", code: 49)
        XCTAssertTrue(list.isPopoverOpen)

        rows = ["zzz", "yyy", "xxx"]
        picker.workspaceFolder = folder.appendingPathComponent("elsewhere")
        spin()

        XCTAssertTrue(list.isPopoverOpen, "the open list survives")
        XCTAssertTrue(picker.dropdownForTesting === list, "and is the same control")
        XCTAssertEqual(picker.catalog, ["aaa", "bbb"], "the catalog it is indexing has not moved")

        press(list, " ", code: 49)
        XCTAssertEqual(picker.carried, ["aaa"], "so a pick means the row that was on screen")

        press(list, "", code: 53)
        spin()

        XCTAssertEqual(
            picker.catalog, ["zzz", "yyy", "xxx", "aaa"],
            "the new catalog, with the pick kept the way any carried entry git stopped ignoring is")
    }

    func test_aResizeClosingTheList_doesNotStrandTheWaitingCatalog() throws {
        var rows = ["aaa", "bbb"]
        let picker = picker(catalogProvider: {
            IgnoredCatalog(entries: rows, resting: rows, fileCounts: [:], directories: [])
        })
        load(picker)
        let list = try XCTUnwrap(picker.dropdownForTesting)
        window?.makeFirstResponder(list)
        press(list, " ", code: 49)

        rows = ["zzz"]
        picker.workspaceFolder = folder.appendingPathComponent("elsewhere")
        spin()
        window?.setFrame(NSRect(x: 0, y: 0, width: 500, height: 500), display: false)
        spin()

        XCTAssertFalse(list.isPopoverOpen, "the resize closed it")
        XCTAssertEqual(picker.catalog, ["zzz"], "and the waiting catalog landed")
    }

    func test_losingTheStopWhileFocused_tellsTheForm() throws {
        let picker = picker(ignoring: [])
        picker.settle = 0.05
        var lost = 0
        picker.onFocusLost = { lost += 1 }
        picker.workspaceFolder = folder
        let stop = try XCTUnwrap(picker.focusStop)
        window?.makeFirstResponder(stop)

        let landed = expectation(description: "catalog")
        picker.onChanged = { landed.fulfill() }
        wait(for: [landed], timeout: 2)

        XCTAssertNil(picker.focusStop, "nothing to stand on any more")
        XCTAssertEqual(lost, 1)
    }

    func test_clearingTheFolder_resetsTheWholeCatalog() {
        let picker = picker(
            catalog: IgnoredCatalog(
                entries: ["log"], resting: ["log"], fileCounts: ["log": 170], directories: ["log"]))
        load(picker)
        XCTAssertNotNil(picker.dropdownForTesting)

        picker.workspaceFolder = nil

        XCTAssertEqual(picker.statusForTesting, "Choose a folder first.")
        XCTAssertEqual(picker.resting, [])
    }

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
