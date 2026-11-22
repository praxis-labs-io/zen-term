import XCTest

@testable import ZenTerm

final class OutputWatchTests: XCTestCase {
    private func screen(_ lines: ClosedRange<Int>, then extra: [String] = []) -> String {
        (lines.map { "line \($0)" } + extra).joined(separator: "\n")
    }

    func test_textAlreadyOnScreenWhenTheWaitBeganIsNotAMatch() {
        var watch = OutputWatch(needle: "ready", baseline: screen(1...5, then: ["server ready", "$ "]))
        XCTAssertFalse(watch.sawNeedle(in: screen(1...5, then: ["server ready", "$ "])))
        XCTAssertFalse(watch.sawNeedle(in: screen(1...5, then: ["server ready", "$ ls"])))
    }

    func test_textPrintedOnAScreenThatHasNotScrolledIsAMatch() {
        var watch = OutputWatch(needle: "ready", baseline: "$ npm run dev")
        XCTAssertFalse(watch.sawNeedle(in: "$ npm run dev\ncompiling"))
        XCTAssertTrue(watch.sawNeedle(in: "$ npm run dev\ncompiling\nserver ready"))
    }

    func test_aNewMatchIsSeenWhileAnOldOneScrollsOffTheTop() {
        var watch = OutputWatch(
            needle: "ready",
            baseline: screen(1...20, then: ["ready", "$ "]).replacingOccurrences(of: "line 1\n", with: "ready\n"))
        XCTAssertTrue(watch.sawNeedle(in: screen(3...20, then: ["ready", "$ ", "again ready"])))
    }

    func test_scrollingPastOldTextFindsNothingNew() {
        var watch = OutputWatch(needle: "ready", baseline: screen(1...20, then: ["ready at 1"]))
        XCTAssertFalse(watch.sawNeedle(in: screen(2...20, then: ["ready at 1", "line 21"])))
        XCTAssertFalse(watch.sawNeedle(in: screen(4...20, then: ["ready at 1", "line 21", "line 22", "line 23"])))
    }

    func test_theCursorLineGrowingIntoTheNeedleIsAMatch() {
        var watch = OutputWatch(needle: "done", baseline: screen(1...10, then: ["building... "]))
        XCTAssertTrue(watch.sawNeedle(in: screen(1...10, then: ["building... done"])))
    }

    func test_aRedrawnScreenOnlyMatchesWhenTheNeedleShowsUpMoreOften() {
        var watch = OutputWatch(needle: "ready", baseline: "a\nb ready\nc\nd")
        XCTAssertFalse(watch.sawNeedle(in: "x\nb ready\ny\nz"))
        XCTAssertTrue(watch.sawNeedle(in: "x\nb ready\nready\nz"))
    }
}
