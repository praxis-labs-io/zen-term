import AppKit
import XCTest

@testable import ZenTerm

/// The shared `DirectoryPickerField` (workspace folder + tool-float directory both use it): a text
/// field plus a Choose button that opens a directory panel. The panel is presented through an
/// injectable seam, so these assert the Choose → present → fill wiring without popping a real
/// `NSOpenPanel` (which would flash a sheet and depend on a live window server).
final class DirectoryPickerFieldTests: XCTestCase {
    func test_chooseButton_isAKeyboardFocusStop() {
        let picker = DirectoryPickerField(placeholder: "Type a path, or Choose")
        XCTAssertTrue(picker.chooseButton.isKeyboardFocusable, "the Choose button must be arrow/Tab reachable")
        XCTAssertEqual(picker.chooseButton.title, "Choose")
    }

    func test_emptyField_opensThePanelAtHome() {
        let picker = DirectoryPickerField(placeholder: "Type a path, or Choose")
        var startedAt: URL?
        picker.presentPanel = { _, start, _ in startedAt = start }

        picker.chooseButton.onTap()

        XCTAssertEqual(
            startedAt, FileManager.default.homeDirectoryForCurrentUser,
            "an empty field opens the picker at home, never wherever it last landed (/Library)")
    }

    func test_filledField_opensThePanelAtTheExistingDirectory() {
        let picker = DirectoryPickerField(placeholder: "Type a path, or Choose")
        let dir = FileManager.default.temporaryDirectory  // a real directory, outside home
        picker.setText(PathDisplay.abbreviatingHome(dir.path))
        var startedAt: URL?
        picker.presentPanel = { _, start, _ in startedAt = start }

        picker.chooseButton.onTap()

        XCTAssertEqual(startedAt?.path, dir.path, "a real path in the field opens the picker there")
    }

    func test_pickingAFolder_fillsTheFieldAndRunsOnPicked() {
        let picker = DirectoryPickerField(placeholder: "Type a path, or Choose")
        var picked: URL?
        picker.onPicked = { picked = $0 }
        let chosen = FileManager.default.homeDirectoryForCurrentUser
        picker.presentPanel = { _, _, completion in completion(chosen) }

        picker.chooseButton.onTap()

        XCTAssertEqual(picker.text, PathDisplay.abbreviatingHome(chosen.path), "the pick fills the field")
        XCTAssertEqual(picked, chosen, "onPicked runs with the chosen URL")
    }

    func test_cancellingThePanel_leavesTheFieldUnchanged() {
        let picker = DirectoryPickerField(placeholder: "Type a path, or Choose")
        picker.setText("~/keep-me")
        var pickedRan = false
        picker.onPicked = { _ in pickedRan = true }
        picker.presentPanel = { _, _, completion in completion(nil) }  // user cancelled

        picker.chooseButton.onTap()

        XCTAssertEqual(picker.text, "~/keep-me", "cancel leaves the typed path intact")
        XCTAssertFalse(pickedRan, "cancel does not run onPicked")
    }
}
