import PaneKit
import XCTest

@testable import ZenTerm

final class NavCommandTests: XCTestCase {
    func test_focus_decodesEachDirection() {
        XCTAssertEqual(
            NavCommand.decode(#"{"cmd":"focus","dir":"left","pane":7}"#), .focus(token: 7, dir: .left))
        XCTAssertEqual(
            NavCommand.decode(#"{"cmd":"focus","dir":"right","pane":7}"#), .focus(token: 7, dir: .right))
        XCTAssertEqual(
            NavCommand.decode(#"{"cmd":"focus","dir":"up","pane":7}"#), .focus(token: 7, dir: .up))
        XCTAssertEqual(
            NavCommand.decode(#"{"cmd":"focus","dir":"down","pane":7}"#), .focus(token: 7, dir: .down))
    }

    func test_setvim_decodesBothStates() {
        XCTAssertEqual(
            NavCommand.decode(#"{"cmd":"setvim","pane":3,"vim":true}"#), .setVim(token: 3, on: true))
        XCTAssertEqual(
            NavCommand.decode(#"{"cmd":"setvim","pane":3,"vim":false}"#), .setVim(token: 3, on: false))
    }

    func test_setvim_missingVimDefaultsToOff() {
        XCTAssertEqual(NavCommand.decode(#"{"cmd":"setvim","pane":3}"#), .setVim(token: 3, on: false))
    }

    func test_ignoresTrailingWhitespaceAndNewline() {
        XCTAssertEqual(
            NavCommand.decode("{\"cmd\":\"focus\",\"dir\":\"left\",\"pane\":1}\n  "),
            .focus(token: 1, dir: .left))
    }

    func test_extraFieldsAreIgnored() {
        XCTAssertEqual(
            NavCommand.decode(#"{"cmd":"focus","dir":"up","pane":2,"extra":"ignored"}"#),
            .focus(token: 2, dir: .up))
    }

    func test_rejectsUnknownDirection() {
        XCTAssertNil(NavCommand.decode(#"{"cmd":"focus","dir":"sideways","pane":1}"#))
    }

    func test_rejectsUnknownCommand() {
        XCTAssertNil(NavCommand.decode(#"{"cmd":"teleport","pane":1}"#))
    }

    func test_rejectsMissingPane() {
        XCTAssertNil(NavCommand.decode(#"{"cmd":"focus","dir":"left"}"#))
    }

    func test_rejectsMalformedJSON() {
        XCTAssertNil(NavCommand.decode("not json"))
        XCTAssertNil(NavCommand.decode(#"{"cmd":"focus","dir":"left","pane":}"#))
        XCTAssertNil(NavCommand.decode(""))
        XCTAssertNil(NavCommand.decode("   "))
    }

    // The log line is the whole point of recording these: a bug report has to name the token
    // and the flag state, or a stale nvim flag is unattributable after the fact.
    func test_logLine_namesTokenAndVimState() {
        XCTAssertEqual(NavCommand.setVim(token: 14, on: true).logLine, "setvim pane=14 vim=true")
        XCTAssertEqual(NavCommand.setVim(token: 14, on: false).logLine, "setvim pane=14 vim=false")
    }

    func test_logLine_namesTokenAndDirection() {
        XCTAssertEqual(NavCommand.focus(token: 7, dir: .left).logLine, "focus pane=7 dir=left")
        XCTAssertEqual(NavCommand.focus(token: 7, dir: .down).logLine, "focus pane=7 dir=down")
    }
}
