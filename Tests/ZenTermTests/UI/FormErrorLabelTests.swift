import XCTest

@testable import ZenTerm

final class FormErrorLabelTests: XCTestCase {
    func test_aLongMessage_doesNotResistHorizontalCompression() {
        let label = FormErrorLabel()
        label.show(String(repeating: "a long failure message ", count: 20))

        XCTAssertEqual(label.contentCompressionResistancePriority(for: .horizontal), .defaultLow)
    }

    func test_reshowingTheSameMessage_announcesItOnce() {
        let label = FormErrorLabel()
        var announced: [String] = []
        label.onAnnounceForTesting = { announced.append($0) }

        label.show("That name is taken.")
        label.show("That name is taken.")
        XCTAssertEqual(announced, ["That name is taken."], "a refresh that re-shows the same text stays silent")

        label.show("The path can't contain a quote.")
        XCTAssertEqual(announced.count, 2, "new text is announced")

        label.clear()
        label.show("The path can't contain a quote.")
        XCTAssertEqual(announced.count, 3, "text shown again after a clear is announced")
    }

    func test_eachTone_takesItsRole() {
        let chrome = Theme.current.chrome
        let label = FormErrorLabel()

        label.show("x", tone: .warning)
        XCTAssertEqual(label.textColor, chrome.warning.nsColor)
        label.show("x", tone: .muted)
        XCTAssertEqual(label.textColor, chrome.ink(.muted))
        label.show("x")
        XCTAssertEqual(label.textColor, chrome.destructive.nsColor)
    }
}
