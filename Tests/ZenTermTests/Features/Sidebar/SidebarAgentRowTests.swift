import AppKit
import XCTest

@testable import ZenTerm

final class SidebarAgentRowTests: WindowTestCase {
    private func summaryLabel(of row: NSView, saying text: String) throws -> NSTextField {
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        return try XCTUnwrap(descendants(row).compactMap { $0 as? NSTextField }.first { $0.stringValue == text })
    }

    func test_theSummary_takesNormalInk_leavingTheStateToTheDot() throws {
        let row = SidebarAgentRow {}
        for state in [AttentionTone.waiting, .working, .idle] {
            row.render(
                SidebarAgentItem(
                    id: SurfaceID(raw: 1), state: state, summary: state.summary, detail: "zen-term", message: nil))

            XCTAssertEqual(
                try summaryLabel(of: row, saying: state.summary).textColor, Theme.current.chrome.ink(.normal),
                "a \(state.summary) agent's summary takes a state color")
        }
    }
}
