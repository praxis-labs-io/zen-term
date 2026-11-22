import ControlProtocol
import XCTest

final class PaneKeyTests: XCTestCase {
    func test_everyKeyGoesByTheNameItParsesFrom() {
        let keys: [PaneKey] = [
            .enter, .escape, .tab, .shiftTab, .backspace, .space, .up, .down, .left, .right, .home, .end, .pageUp,
            .pageDown, .control("a"), .control("z"),
        ]
        for key in keys { XCTAssertEqual(PaneKey(name: key.name), key, key.name) }
    }

    func test_onlyALowercaseLetterFollowsCtrl() {
        for name in ["ctrl-", "ctrl-1", "ctrl-ab", "ctrl-C", "Enter", "ctrl+c", ""] {
            XCTAssertNil(PaneKey(name: name), name)
        }
    }
}
