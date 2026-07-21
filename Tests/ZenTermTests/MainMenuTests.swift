import AppKit
import XCTest

@testable import ZenTerm

final class MainMenuTests: XCTestCase {
    func test_helpMenu_carriesReportAnIssueAndExportDiagnostics() {
        let app = NSApplication.shared  // initializes NSApp, which MainMenu.install assigns into
        let saved = app.mainMenu
        defer { app.mainMenu = saved }

        MainMenu.install(copyPaste: nil)

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
