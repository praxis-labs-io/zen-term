import XCTest

@testable import ZenTerm

final class SessionFontSizeTests: XCTestCase {
    private func config(fontSize: CGFloat) -> GeneralConfig {
        var config = GeneralConfig.builtIn
        config.fontSize = fontSize
        return config
    }

    override func setUp() {
        super.setUp()
        SessionFontSize.seed(from: config(fontSize: 14))
    }

    override func tearDown() {
        SessionFontSize.seed(from: GeneralConfig.builtIn)
        super.tearDown()
    }

    func test_stepsByWholePoints() {
        SessionFontSize.step(by: 1)
        XCTAssertEqual(SessionFontSize.points, 15)
        SessionFontSize.step(by: 1)
        XCTAssertEqual(SessionFontSize.points, 16)
        SessionFontSize.step(by: -1)
        XCTAssertEqual(SessionFontSize.points, 15)
    }

    func test_clampsAtBothEnds() {
        for _ in 0..<50 { SessionFontSize.step(by: 1) }
        XCTAssertEqual(SessionFontSize.points, SessionFontSize.range.upperBound)
        for _ in 0..<50 { SessionFontSize.step(by: -1) }
        XCTAssertEqual(SessionFontSize.points, SessionFontSize.range.lowerBound)
    }

    func test_resetReturnsToTheConfigSize() {
        SessionFontSize.step(by: 4)
        SessionFontSize.reset()
        XCTAssertEqual(SessionFontSize.points, 14)
    }

    func test_reload_withUnchangedFontSize_keepsTheSteppedSize() {
        SessionFontSize.step(by: 4)
        XCTAssertFalse(SessionFontSize.reseedIfBaseChanged(from: config(fontSize: 14)))
        XCTAssertEqual(SessionFontSize.points, 18)
    }

    func test_reload_withChangedFontSize_adoptsIt() {
        SessionFontSize.step(by: 4)
        XCTAssertTrue(SessionFontSize.reseedIfBaseChanged(from: config(fontSize: 20)))
        XCTAssertEqual(SessionFontSize.points, 20)
    }

    func test_resetAfterAReload_usesTheNewBase() {
        SessionFontSize.reseedIfBaseChanged(from: config(fontSize: 20))
        SessionFontSize.step(by: 3)
        SessionFontSize.reset()
        XCTAssertEqual(SessionFontSize.points, 20)
    }

    func test_display_readsAsPoints() {
        XCTAssertEqual(SessionFontSize.display, "14pt")
        SessionFontSize.step(by: 2)
        XCTAssertEqual(SessionFontSize.display, "16pt")
    }

    func test_display_keepsAFractionalConfigSize() {
        SessionFontSize.seed(from: config(fontSize: 14.5))
        XCTAssertEqual(SessionFontSize.display, "14.5pt")
    }
}
