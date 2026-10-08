import ControlProtocol
import XCTest

final class ControlRequestTests: XCTestCase {
    private func decode(_ line: String) -> Result<ControlRequest, ControlRequest.Rejection> {
        ControlRequest.decode(Data(line.utf8))
    }

    private func rejection(_ line: String) -> ControlRequest.Rejection? {
        guard case .failure(let rejection) = decode(line) else { return nil }
        return rejection
    }

    func test_decodesAWellFormedRequest() {
        XCTAssertEqual(
            try decode(#"{"v":1,"id":7,"cmd":"list","caller":{"pane":31}}"#).get(),
            ControlRequest(id: 7, cmd: .list, caller: ControlCaller(pane: 31)))
    }

    func test_decodesWithATrailingNewlineAndUnknownFields() {
        XCTAssertEqual(
            try decode("{\"v\":1,\"id\":2,\"cmd\":\"hello\",\"args\":{\"x\":1}}\n").get(),
            ControlRequest(id: 2, cmd: .hello))
    }

    func test_garbageIsABadRequestWithNoID() {
        let rejection = rejection("garbage not json")
        XCTAssertEqual(rejection?.error.code, .badRequest)
        XCTAssertNil(rejection?.id)
    }

    func test_aNonObjectIsABadRequest() {
        XCTAssertEqual(rejection("[1,2]")?.error.code, .badRequest)
    }

    func test_missingVersionIsABadRequestThatKeepsTheID() {
        let rejection = rejection(#"{"id":4,"cmd":"list"}"#)
        XCTAssertEqual(rejection?.error.code, .badRequest)
        XCTAssertEqual(rejection?.id, 4)
    }

    func test_missingIDIsABadRequest() {
        XCTAssertEqual(rejection(#"{"v":1,"cmd":"list"}"#)?.error.code, .badRequest)
    }

    func test_aStringIDIsABadRequest() {
        XCTAssertEqual(rejection(#"{"v":1,"id":"a","cmd":"list"}"#)?.error.code, .badRequest)
    }

    func test_missingCommandIsABadRequestThatKeepsTheID() {
        let rejection = rejection(#"{"v":1,"id":5}"#)
        XCTAssertEqual(rejection?.error.code, .badRequest)
        XCTAssertEqual(rejection?.id, 5)
    }

    func test_unknownCommandIsUnknownCommand() {
        let rejection = rejection(#"{"v":1,"id":6,"cmd":"tab.explode"}"#)
        XCTAssertEqual(rejection?.error.code, .unknownCommand)
        XCTAssertEqual(rejection?.id, 6)
    }

    func test_newerVersionIsUnsupportedAndNamesTheSpokenOne() {
        let rejection = rejection(#"{"v":2,"id":8,"cmd":"list"}"#)
        XCTAssertEqual(rejection?.error.code, .unsupportedVersion)
        XCTAssertEqual(rejection?.id, 8)
        XCTAssertTrue(rejection?.error.message.contains("version 1") == true, "\(String(describing: rejection))")
    }

    func test_encodedRequestRoundTrips() throws {
        let request = ControlRequest(id: 3, cmd: .hello, caller: ControlCaller(pane: 9))
        let line = try ControlWire.line(request)
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(try ControlRequest.decode(line).get(), request)
    }

    func test_decodesArgsAndIgnoresFieldsTheyDoNotTake() {
        XCTAssertEqual(
            try decode(#"{"v":1,"id":9,"cmd":"tab.new","args":{"cmd":"npm run dev","focus":true,"x":1}}"#).get(),
            ControlRequest(id: 9, cmd: .tabNew, args: ControlArgs(cmd: "npm run dev", focus: true)))
    }

    func test_nullArgsAreNoArgs() {
        XCTAssertEqual(
            try decode(#"{"v":1,"id":9,"cmd":"tab.close","args":null}"#).get(), ControlRequest(id: 9, cmd: .tabClose))
    }

    func test_mistypedArgsAreABadRequestThatKeepsTheID() {
        let mistyped = rejection(#"{"v":1,"id":10,"cmd":"tab.close","args":{"force":"yes"}}"#)
        XCTAssertEqual(mistyped?.error.code, .badRequest)
        XCTAssertEqual(mistyped?.id, 10)
        XCTAssertEqual(rejection(#"{"v":1,"id":11,"cmd":"tab.close","args":[1]}"#)?.error.code, .badRequest)
    }

    func test_requestWithArgsRoundTrips() throws {
        let request = ControlRequest(
            id: 4, cmd: .workspaceOpen, args: ControlArgs(workspace: "/src/app", focus: true),
            caller: ControlCaller(pane: 2))
        XCTAssertEqual(try ControlRequest.decode(ControlWire.line(request)).get(), request)
    }

    func test_everyCommandHasItsWireName() {
        XCTAssertEqual(
            ControlCommand.allCases.map(\.rawValue),
            [
                "hello", "list", "workspace.open", "workspace.new", "workspace.switch", "workspace.close", "tab.new",
                "tab.select", "tab.rename", "tab.close",
                "pane.split", "pane.focus", "pane.close", "pane.send", "pane.read",
                "worktree.list", "worktree.create", "worktree.remove", "action",
            ])
    }

    func test_paneArgsRoundTripAndAnUnknownDirectionIsABadRequest() throws {
        let request = ControlRequest(
            id: 5, cmd: .paneSplit,
            args: ControlArgs(cmd: "make watch", pane: 31, dir: .down, text: "x", enter: true, lines: 3))
        XCTAssertEqual(try ControlRequest.decode(ControlWire.line(request)).get(), request)
        let line = Data(#"{"v":1,"id":6,"cmd":"pane.split","args":{"dir":"left"}}"#.utf8)
        guard case .failure(let rejection) = ControlRequest.decode(line) else { return XCTFail("decoded a left split") }
        XCTAssertEqual(rejection.error.code, .badRequest)
    }
}
