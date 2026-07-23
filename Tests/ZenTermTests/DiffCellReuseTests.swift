import AppKit
import XCTest

@testable import ZenTerm

/// A reused row must resize its text to the new line immediately. `configure` used to only mark the cell
/// as needing layout, so a cell recycled from a shorter row kept that row's narrow text frame and clipped
/// the new line's tail (whole lines rendered blank when the previous row was very short) until some other
/// pass ran — visible as "missing text" in the diff (ZEN-239). Window-based, because the bug is in the
/// frame the label actually gets, which a view-model assertion can't see.
final class DiffCellReuseTests: XCTestCase {
    private let shortLine = "] as"
    private let longLine = "export type NoteableType = (typeof NOTEABLE_TYPES)[number];"

    private func window(hosting view: NSView) -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 1200, height: 20)
        return win
    }

    private func labels(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(labels)
    }

    private func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: DiffCellMetrics.font]).width
    }

    func test_splitCell_reusedFromShorterRow_sizesTextToTheNewLine() {
        let cell = DiffLineCell()
        _ = window(hosting: cell)

        cell.configure(.split(left: DiffCell(lineNumber: 1, text: shortLine, kind: .context, spans: nil), right: nil))
        cell.layoutSubtreeIfNeeded()
        cell.configure(.split(left: DiffCell(lineNumber: 2, text: longLine, kind: .context, spans: nil), right: nil))

        // No explicit layout pass here — that's the point: the table may draw the reused cell first.
        let label = labels(cell).first { $0.stringValue == longLine }
        XCTAssertEqual(
            label?.frame.width ?? 0, width(of: longLine), accuracy: 1,
            "reused split cell must widen to the new line, not keep the previous row's frame")
    }

    func test_inlineCell_reusedFromShorterRow_sizesTextToTheNewLine() {
        let cell = UnifiedLineCell()
        _ = window(hosting: cell)

        cell.configure(.unified(text: shortLine, kind: .context, old: 1, new: 1, spans: nil))
        cell.layoutSubtreeIfNeeded()
        cell.configure(.unified(text: longLine, kind: .context, old: 2, new: 2, spans: nil))

        let label = labels(cell).first { $0.stringValue == longLine }
        XCTAssertEqual(
            label?.frame.width ?? 0, width(of: longLine), accuracy: 1,
            "reused inline cell must widen to the new line, not keep the previous row's frame")
    }
}
