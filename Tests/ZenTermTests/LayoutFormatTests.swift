import XCTest
@testable import ZenTerm

final class LayoutFormatTests: XCTestCase {
    func test_number_trimsTrailingZeros() {
        XCTAssertEqual(LayoutFormat.number(0.82), "0.82")
        XCTAssertEqual(LayoutFormat.number(8), "8")
        XCTAssertEqual(LayoutFormat.number(0.3), "0.3")
        XCTAssertEqual(LayoutFormat.number(0.70), "0.7")
    }

    func test_parseNumber_rejectsNonNumericAndOutOfRange() {
        XCTAssertNil(LayoutFormat.parseNumber("abc", in: 0...64))
        XCTAssertNil(LayoutFormat.parseNumber("", in: 0...64))
        XCTAssertNil(LayoutFormat.parseNumber("99", in: 0...64))
        XCTAssertNil(LayoutFormat.parseNumber("-1", in: 0...64))
    }

    func test_parseNumber_acceptsInRange() {
        XCTAssertEqual(LayoutFormat.parseNumber("8", in: 0...64), 8)
        XCTAssertEqual(LayoutFormat.parseNumber(" 0.82 ", in: 0...1), 0.82)
    }

    func test_reduceMotion_indexRoundTrips() {
        for (index, r) in [(0, GeneralConfig.ReduceMotion.system), (1, .on), (2, .off)] {
            XCTAssertEqual(LayoutFormat.reduceMotion(fromIndex: index), r)
            XCTAssertEqual(LayoutFormat.reduceMotionIndex(r), index)
        }
        XCTAssertEqual(LayoutFormat.reduceMotionToken(.on), "on")
    }

    func test_args_joinSplitRoundTrips() {
        XCTAssertEqual(LayoutFormat.joinArgs(["-l", "--login"]), "-l --login")
        XCTAssertEqual(LayoutFormat.splitArgs("  -l   --login "), ["-l", "--login"])
        XCTAssertEqual(LayoutFormat.splitArgs(""), [])
    }
}
