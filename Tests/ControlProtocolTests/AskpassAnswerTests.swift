import ControlProtocol
import Foundation
import XCTest

final class AskpassAnswerTests: XCTestCase {
    private let secret = "hunter2-sentinel"

    func test_theAnswerTravelsAsABareString() throws {
        let line = try AskpassResult(answer: AskpassAnswer(secret)).responseLine(id: 3)
        let text = String(decoding: line, as: UTF8.self)
        XCTAssertTrue(text.contains(#""result":{"answer":"hunter2-sentinel"}"#), text)
        let decoded = try JSONDecoder().decode(ControlResponse<AskpassResult>.self, from: line)
        XCTAssertEqual(decoded.result?.answer.text, secret)
    }

    func test_noDescriptionOfTheAnswerOrItsResultShowsTheText() {
        let answer = AskpassAnswer(secret)
        let result = AskpassResult(answer: answer)
        var dumped = ""
        dump(result, to: &dumped)
        let renderings = [
            "\(answer)", String(reflecting: answer), "\(result)", String(reflecting: result), dumped,
            "\(Mirror(reflecting: result).children.map { "\($0.value)" })",
        ]
        for rendering in renderings { XCTAssertFalse(rendering.contains(secret), rendering) }
    }

    func test_askpassArgsRoundTripWithTheirWireNames() throws {
        let request = ControlRequest(
            id: 7, cmd: .sshAskpass, args: ControlArgs(token: "t0k", prompt: "-x's password: ", sshPID: 4242))
        let line = try ControlWire.line(request)
        XCTAssertTrue(String(decoding: line, as: UTF8.self).contains(#""ssh_pid":4242"#))
        XCTAssertEqual(try ControlRequest.decode(line).get(), request)
    }
}
