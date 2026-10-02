import ArgumentParser
import ControlProtocol
import XCTest

@testable import zen

final class WorkspaceTabCommandTests: XCTestCase {
    func test_aWorkspaceIsAFolderOnlyWhenItLooksLikeOne() {
        XCTAssertEqual(CommandPath.workspace("./app", in: "/src"), "/src/app")
        XCTAssertEqual(CommandPath.workspace("../app", in: "/src/zen"), "/src/app")
        XCTAssertEqual(CommandPath.workspace("/src/app/", in: "/x"), "/src/app")
        XCTAssertEqual(CommandPath.workspace("~", in: "/x"), NSHomeDirectory())
        XCTAssertEqual(CommandPath.workspace("zen-term: feat/x", in: "/src"), "zen-term: feat/x")
        XCTAssertEqual(CommandPath.workspace("ssh:devbox", in: "/src"), "ssh:devbox")
    }

    func test_aFolderArgumentMustExist() throws {
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        XCTAssertEqual(try CommandPath.folder(".", in: tmp), tmp)
        XCTAssertThrowsError(try CommandPath.folder("missing-\(UUID().uuidString)", in: tmp))
        XCTAssertEqual(Zen.exitCode(running: ["tab", "new", "--cwd", "/nowhere-\(UUID().uuidString)"]), 2)
    }

    func test_theSubcommandsParseTheirArguments() throws {
        let tabNew = try XCTUnwrap(
            try Zen.parseAsRoot(["tab", "new", "--cmd", "npm run dev", "--focus", "--socket", "/a.sock"])
                as? TabCommands.New)
        XCTAssertEqual(tabNew.cmd, "npm run dev")
        XCTAssertTrue(tabNew.focus)
        XCTAssertEqual(tabNew.connection.socket, "/a.sock")

        let close = try XCTUnwrap(try Zen.parseAsRoot(["tab", "close", "w1.t3", "--force"]) as? TabCommands.Close)
        XCTAssertEqual(close.tab, "w1.t3")
        XCTAssertTrue(close.force)

        let rename = try XCTUnwrap(try Zen.parseAsRoot(["tab", "rename", ""]) as? TabCommands.Rename)
        XCTAssertEqual(rename.title, "")

        let open = try XCTUnwrap(try Zen.parseAsRoot(["workspace", "open", "alpha"]) as? WorkspaceCommands.Open)
        XCTAssertEqual(open.workspace, "alpha")
        XCTAssertFalse(open.focus)
    }

    func test_theSocketBeforeANestedSubcommandIsUsed() throws {
        let select = try XCTUnwrap(
            try Zen.parseAsRoot(["--socket", "/a.sock", "tab", "select"]) as? TabCommands.Select)
        XCTAssertEqual(select.connection.socket, "/a.sock")
    }

    func test_aRefusalNamesWhatItWouldStopAndTheWayPast() {
        let refusal = ControlError(
            .refused, "Closing tab w1.t3 would stop npm run dev.",
            details: .init(
                panes: [.init(token: 31, drawer: nil, title: "npm run dev", cwd: "/app", busy: true, agent: nil)],
                floats: ["Scratch"], closesWindow: false))

        XCTAssertEqual(
            ControlClient.describe(refusal),
            """
            Closing tab w1.t3 would stop npm run dev. (refused)
              31  npm run dev  /app
              Scratch float
            Pass --force to go ahead.
            """)
        XCTAssertEqual(ControlClient.describe(ControlError(.notFound, "No tab.")), "No tab. (not_found)")
    }
}
