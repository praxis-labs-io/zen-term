import AppKit
import XCTest

@testable import ZenTerm

final class MainMenuTests: XCTestCase {
    /// AppKit's own selectors with no target, so the responder chain decides who serves them. A
    /// custom selector or an explicit target walks past the focused field, which is what left ⌘A
    /// dead and ⌘C copying the buffer while you typed in the find bar.
    func test_editMenu_carriesTheStandardVerbsWithNoTarget() {
        let app = NSApplication.shared
        let saved = app.mainMenu
        defer { app.mainMenu = saved }

        MainMenu.install()

        let edit = app.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
        let expected: [(String, Selector, String)] = [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
        for (title, action, key) in expected {
            let item = edit?.items.first { $0.title == title }
            XCTAssertEqual(item?.action, action, "\(title) routes by selector")
            XCTAssertEqual(item?.keyEquivalent, key)
            XCTAssertEqual(item?.keyEquivalentModifierMask, .command)
            XCTAssertNil(item?.target, "\(title) must have no target, or it beats the focused field")
        }
    }

    /// Undo, Redo and Cut reach a field editor from these key equivalents and from nowhere else:
    /// macOS ships no default key binding for them. A bare `NSTextView` also needs `allowsUndo`, or
    /// the item greys out in the two boxes people write paragraphs in.
    func test_theMultilineBoxes_allowUndo() {
        XCTAssertTrue(TextAreaBox(placeholder: "note").textView.allowsUndo)
    }

    func test_helpMenu_carriesReportAnIssueAndExportDiagnostics() {
        let app = NSApplication.shared  // initializes NSApp, which MainMenu.install assigns into
        let saved = app.mainMenu
        defer { app.mainMenu = saved }

        MainMenu.install()

        let help = app.mainMenu?.items.first { $0.submenu?.title == "Help" }?.submenu
        XCTAssertNotNil(help, "there is a Help menu")
        XCTAssertEqual(
            help?.items.first { $0.title == "Report an Issue…" }?.action,
            #selector(AppDelegate.reportAnIssue(_:)))
        XCTAssertEqual(
            help?.items.first { $0.title == "Export Diagnostics…" }?.action,
            #selector(AppDelegate.exportDiagnostics(_:)))
    }
}
