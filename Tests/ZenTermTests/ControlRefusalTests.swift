import ControlProtocol
import XCTest

@testable import ZenTerm

final class ControlRefusalTests: XCTestCase {
    func test_aCloseRefusalListsWhatItWouldEndAsOneSentence() {
        let panes = [
            ListResult.Pane(token: 31, drawer: nil, title: "npm run dev", cwd: nil, busy: true, agent: nil),
            ListResult.Pane(token: 32, drawer: nil, title: "", cwd: nil, busy: true, agent: nil),
        ]
        let stakes = CloseStakes(closesWindow: true, isRunning: true, panes: panes, floats: ["Scratch"])

        XCTAssertEqual(
            ControlResponder.refusal(closing: "tab w1.t3", stakes).message,
            "Closing tab w1.t3 would close the window and stop npm run dev, pane 32 and Scratch.")
    }
}
