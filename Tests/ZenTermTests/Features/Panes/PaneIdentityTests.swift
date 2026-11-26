import XCTest

@testable import ZenTerm

final class PaneIdentityTests: XCTestCase {
    private let project = URL(fileURLWithPath: PathDisplay.homePath).appendingPathComponent("dev/zen-term")
    private let nvim = PaneIdentity.Running(process: ProcessIcon.forProgram("nvim"), name: "nvim")

    private func tab(_ title: String?) -> String { PaneIdentity.tabTitle(title: title, directory: project) }

    func test_theHeader_isWhatRunsAndWhere() {
        let content = PaneIdentity.header(named: nil, running: nvim, directory: project)
        XCTAssertEqual(content.name, "nvim")
        XCTAssertEqual(content.path, "~/dev/zen-term")
        XCTAssertEqual(content.process, nvim.process)
    }

    func test_aGivenName_outranksWhatRuns_inTheHeader() {
        XCTAssertEqual(PaneIdentity.header(named: "tests", running: nvim, directory: project).name, "tests")
        XCTAssertEqual(PaneIdentity.header(named: "", running: nvim, directory: project).name, "nvim")
    }

    func test_aTab_readsTheTitleItsPaneReports() {
        XCTAssertEqual(tab("cargo build"), "cargo build")
        XCTAssertEqual(tab("drew@devbox: ~/src"), "drew@devbox: ~/src", "a title that only carries a path is kept")
    }

    func test_aTab_dropsTheStatusAnAgentLeadsItsTitleWith() {
        XCTAssertEqual(tab("✳ Pane headers"), "Pane headers")
        XCTAssertEqual(tab("⠂ Pane headers"), "Pane headers", "the spinner frame never makes the tab flicker")
        XCTAssertEqual(tab("[ ! ] Needs approval"), "Needs approval")
        XCTAssertEqual(tab("(draft) notes"), "(draft) notes", "a leading bracket is the title's own")
    }

    func test_aTab_neverShowsAFullPath() {
        XCTAssertEqual(tab("~/dev/zen-term"), "zen-term")
        XCTAssertEqual(tab("…/Frameworks/AppKit.framework/Resources"), "Resources", "ghostty's short form too")
        XCTAssertEqual(tab("~"), PathDisplay.homeName, "home reads as its own name, never a lone ~")
    }

    func test_aTabWithNoTitle_readsItsFolder() {
        XCTAssertEqual(tab(""), "zen-term")
        XCTAssertEqual(PaneIdentity.tabTitle(title: nil, directory: nil), "shell")
    }
}
