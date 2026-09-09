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
        let picker = CarryPicker()
        picker.settle = 0
        picker.probe = { _ in ignored }
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
        picker.probe = {
            asked.append($0.path); return []
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
