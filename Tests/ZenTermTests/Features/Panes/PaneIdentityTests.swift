import XCTest

@testable import ZenTerm

final class PaneIdentityTests: XCTestCase {
    private let project = URL(fileURLWithPath: PathDisplay.homePath).appendingPathComponent("Dev/zen-term")
    private var path: String { PathDisplay.abbreviatingHome(project.path) }

    private func label(named name: String? = nil, title: String?, program: String?) -> String {
        PaneIdentity.label(named: name, title: title, program: program, directory: project).text
    }

    func test_aNamedPane_isItsName_whateverItsProgramTitlesItself() {
        XCTAssertEqual(label(named: "tests", title: "✳ Running", program: "claude"), "tests")
    }

    func test_aTitleTheRunningProgramSets_isTheLabel() {
        XCTAssertEqual(label(title: "✳ Pane headers", program: "claude"), "✳ Pane headers")
        XCTAssertEqual(label(title: "drew@devbox: ~/src", program: "ssh"), "drew@devbox: ~/src")
    }

    func test_theCommandLineTheShellEchoes_isNotATitle() {
        XCTAssertEqual(label(title: "nvim a.swift", program: "nvim"), path, "the tab already names the program")
        XCTAssertEqual(label(title: "/usr/bin/nvim a.swift", program: "nvim"), path)
    }

    func test_atAPrompt_theShellsOwnTitle_givesWayToThePath() {
        XCTAssertEqual(label(title: "…/dev/zen-term", program: nil), path, "one form of the path, always ours")
    }

    func test_withNothingAtAll_theFallbackIsTheLabel() {
        XCTAssertEqual(PaneIdentity.label(named: nil, title: nil, program: nil, directory: nil).text, "shell")
        XCTAssertEqual(
            PaneIdentity.label(named: nil, title: nil, program: "zen-octo", directory: nil, otherwise: "Octo").text,
            "Octo")
    }

    func test_onlyAPath_isMarkedAsOne() {
        XCTAssertTrue(PaneIdentity.label(named: nil, title: nil, program: nil, directory: project).isPath)
        XCTAssertFalse(PaneIdentity.label(named: "tests", title: nil, program: nil, directory: project).isPath)
        XCTAssertFalse(PaneIdentity.label(named: nil, title: "✳ Task", program: "claude", directory: project).isPath)
    }
}
