import XCTest

@testable import ZenTerm

final class FormErrorLabelTests: XCTestCase {
    func test_aLongMessage_doesNotResistHorizontalCompression() {
        let label = FormErrorLabel()
        label.show(String(repeating: "a long failure message ", count: 20))

        XCTAssertEqual(label.contentCompressionResistancePriority(for: .horizontal), .defaultLow)
    }
}
