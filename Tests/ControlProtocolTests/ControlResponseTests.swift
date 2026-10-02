import ControlProtocol
import XCTest

final class ControlResponseTests: XCTestCase {
    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func test_successLineIsOneLineCarryingVersionIDAndResult() throws {
        let line = try HelloResult(app: "1.2.3").responseLine(id: 4)
        XCTAssertEqual(
            text(line), "{\"id\":4,\"ok\":true,\"result\":{\"app\":\"1.2.3\",\"protocol\":1},\"v\":1}\n")
    }

    func test_errorLineCarriesTheWireCode() throws {
        let line = try ControlError(.unknownCommand, "There is no command named x.").responseLine(id: 2)
        XCTAssertEqual(
            text(line),
            "{\"error\":{\"code\":\"unknown_command\",\"message\":\"There is no command named x.\"},"
                + "\"id\":2,\"ok\":false,\"v\":1}\n")
    }

    func test_errorWithNoIDSendsNull() throws {
        let line = try ControlError(.badRequest, "no").responseLine(id: nil)
        XCTAssertTrue(text(line).contains("\"id\":null"), text(line))
    }

    func test_pathsAreNotSlashEscaped() throws {
        let line = try ControlWire.line(ListResult.Worktree(name: "x", parent: "/a/b"))
        XCTAssertEqual(text(line), "{\"name\":\"x\",\"parent\":\"/a/b\"}\n")
    }

    func test_everyErrorCodeHasItsWireName() {
        XCTAssertEqual(
            ControlErrorCode.allCases.map(\.rawValue),
            ["bad_request", "unknown_command", "unsupported_version", "not_found", "ambiguous", "refused", "failed"])
    }

    func test_listResultRoundTrips() throws {
        let list = ListResult(windows: [
            .init(
                id: "w1", key: true,
                workspaces: [
                    .init(
                        title: "zen-term", folder: "/src/zen-term", configured: true,
                        worktree: .init(name: "feat-x", parent: "/src/zen"), active: true,
                        tabs: [
                            .init(
                                id: "w1.t2", title: "zsh", active: true,
                                panes: [
                                    .init(
                                        token: 31, drawer: nil, title: "vim", cwd: "/src", busy: true,
                                        agent: .init(name: "claude", state: .waiting)),
                                    .init(token: 32, drawer: .bottom, title: "", cwd: nil, busy: false, agent: nil),
                                ])
                        ])
                ])
        ])
        let line = try list.responseLine(id: 1)
        let decoded = try JSONDecoder().decode(ControlResponse<ListResult>.self, from: line)
        XCTAssertEqual(decoded.result, list)
        XCTAssertEqual(decoded.id, 1)
        XCTAssertTrue(decoded.ok)
    }

    func test_tabAddressCarriesWindowAndTab() {
        XCTAssertEqual(ControlAddress.tab(window: 1, tab: 14), "w1.t14")
        XCTAssertEqual(ControlAddress.window(3), "w3")
    }

    func test_tabAddressReadsBack() {
        XCTAssertEqual(ControlAddress.tab("w1.t14").map { [$0.window, $0.tab] }, [1, 14])
        for malformed in ["w1", "t14", "w1.t", "1.14", "w1.t14.x", "wx.t1", ""] {
            XCTAssertNil(ControlAddress.tab(malformed), malformed)
        }
    }

    func test_workspaceAddressIsAFolderAHostOrATitle() {
        XCTAssertEqual(ControlAddress.Workspace("/src/app"), .folder("/src/app"))
        XCTAssertEqual(ControlAddress.Workspace("ssh:devbox"), .host("devbox"))
        XCTAssertEqual(ControlAddress.Workspace("zen-term: feat/x"), .title("zen-term: feat/x"))
    }

    func test_aRefusalCarriesWhatForceWouldEnd() throws {
        let pane = ListResult.Pane(token: 31, drawer: nil, title: "npm run dev", cwd: "/app", busy: true, agent: nil)
        let refusal = ControlError(
            .refused, "Closing tab w1.t3 would stop npm run dev.",
            details: .init(panes: [pane], floats: ["Scratch"], closesWindow: false))
        let line = try refusal.responseLine(id: 5)
        XCTAssertTrue(text(line).contains(#""closesWindow":false"#), text(line))
        let decoded = try JSONDecoder().decode(ControlResponse<NoPayload>.self, from: line)
        XCTAssertEqual(decoded.error, refusal)
    }

    func test_aWorktreeRefusalCarriesItsFiles_andACloseRefusalOmitsThem() throws {
        let removal = ControlError(
            .refused, "Removing feat/x loses 1 uncommitted file.",
            details: .init(panes: [], floats: [], closesWindow: false, files: ["notes.txt"], lostCommits: 0))
        let line = try removal.responseLine(id: 6)
        XCTAssertTrue(text(line).contains(#""files":["notes.txt"]"#), text(line))
        XCTAssertEqual(try JSONDecoder().decode(ControlResponse<NoPayload>.self, from: line).error, removal)

        let close = ControlError(.refused, "", details: .init(panes: [], floats: [], closesWindow: true))
        XCTAssertFalse(text(try close.responseLine(id: 7)).contains("files"))
    }

    func test_socketFileNamesMatchOnlyControlSockets() {
        XCTAssertTrue(ControlEndpoint.isSocketFileName("control.123.sock"))
        XCTAssertFalse(ControlEndpoint.isSocketFileName("nav.123.sock"))
        XCTAssertFalse(ControlEndpoint.isSocketFileName("control..sock"))
        XCTAssertFalse(ControlEndpoint.isSocketFileName("control.123.sock.bak"))
    }
}
