import XCTest

@testable import ZenTerm

final class PaneIdentityTests: XCTestCase {
    private let home = URL(fileURLWithPath: PathDisplay.homePath)
    private var project: URL { home.appendingPathComponent("Dev/zen-term") }

    private func header(
        named name: String? = nil, _ foreground: PaneIdentity.Foreground, program: String? = nil,
        title: String? = nil
    ) -> PaneHeader.Content {
        PaneIdentity.header(
            named: name, foreground: foreground, program: program, title: title, directory: project,
            process: .shell)
    }

    func test_anIdleShell_isItsShellAndItsFolder() {
        let content = header(.shell(arguments: ["-zsh"]))
        XCTAssertEqual(content.name, "zsh")
        XCTAssertEqual(content.detail, "~/Dev/zen-term")
    }

    func test_anIdleShell_ignoresTheTitleItSets() {
        let content = header(.shell(arguments: ["-zsh"]), title: "~/Dev/zen-term")
        XCTAssertEqual(content.name, "zsh", "the shell's own title only repeats the folder the detail shows")
    }

    func test_aNamedPane_isItsName_withNoDetail() {
        let content = header(named: "tests", .job(group: 1, arguments: ["swift", "test"]), program: "swift")
        XCTAssertEqual(content.name, "tests")
        XCTAssertNil(content.detail)
    }

    func test_aProgram_isItsNameAndArguments() {
        let content = header(
            .job(group: 1, arguments: ["nvim", PathDisplay.homePath + "/notes.md"]), program: "nvim")
        XCTAssertEqual(content.name, "nvim")
        XCTAssertEqual(content.detail, "~/notes.md")
    }

    func test_aProgramWithNoArguments_fallsBackToTheFolder() {
        let content = header(.job(group: 1, arguments: ["htop"]), program: "htop")
        XCTAssertEqual(content.name, "htop")
        XCTAssertEqual(content.detail, "~/Dev/zen-term")
    }

    func test_aScript_dropsItsInterpreter() {
        let content = header(
            .job(group: 1, arguments: ["node", "/opt/bin/gemini", "--yolo"]), program: "gemini")
        XCTAssertEqual(content.name, "gemini")
        XCTAssertEqual(content.detail, "--yolo")
    }

    func test_aTitleTheProgramSets_replacesItsName() {
        let content = header(.job(group: 1, arguments: ["claude"]), program: "claude", title: "✳ Pane headers")
        XCTAssertEqual(content.name, "✳ Pane headers")
        XCTAssertNil(content.detail)
    }

    func test_aTitleEchoingTheCommandLine_isNotTheProgramsOwn() {
        let content = header(
            .job(group: 1, arguments: ["nvim", "a.swift"]), program: "nvim", title: "nvim a.swift")
        XCTAssertEqual(content.name, "nvim")
        XCTAssertEqual(content.detail, "a.swift")
    }

    func test_aFolderTitleLeftBehindByTheShell_isNotTheProgramsOwn() {
        let content = header(.job(group: 1, arguments: ["htop"]), program: "htop", title: "~/Dev/zen-term")
        XCTAssertEqual(content.name, "htop")
    }

    func test_aHostPane_isTheTitleItsShellSets() {
        XCTAssertEqual(header(.remote, title: "drew@devbox: ~/src").name, "drew@devbox: ~/src")
        let untitled = header(.remote)
        XCTAssertEqual(untitled.name, "shell")
        XCTAssertEqual(untitled.detail, "~/Dev/zen-term")
    }
}
