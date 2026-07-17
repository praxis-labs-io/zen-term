import AppKit
import XCTest

@testable import ZenTerm

/// Two things about `UpdateCardView` that the eye can't verify at a glance:
///
/// 1. The notes column wraps at the card's *real* inner width. This is the one measured budget
///    (the same reason `ToastView.messageMaxWidth` is measured): a bullet that overruns the column
///    or wraps early is invisible until you see the exact release, so we pin the exposed
///    `notesMaxWidth` to the width the mounted card actually lays the notes out at. Placement,
///    color, and motion stay in the runbook.
/// 2. The bullet parser turns the appcast's markdown `<description>` into clean lines. Pure logic
///    that can silently rot (stop stripping the dash, leak blank lines), so it's unit-tested.
final class UpdateCardTests: XCTestCase {
    // MARK: - Measured: the notes column wraps at the real inner width

    func test_notesColumn_wrapsAtTheExposedBudgetWidth() {
        // A line far wider than the column, so it must wrap — its label width is then pinned to the
        // column, not its text.
        let card = UpdateCardView(
            state: .available(
                version: "0.2.0",
                current: "You're on 0.1.4",
                notes: [String(repeating: "wrap ", count: 40)],
                notesURL: nil),
            actions: .init())
        card.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let content = window.contentView!
        content.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: content.topAnchor),
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        ])
        content.layoutSubtreeIfNeeded()

        let notes = firstTextField(in: card) { $0.hasPrefix("•") }
        let label = try? XCTUnwrap(notes)
        // The honest wrap column is the alignment rect, not the frame: a wrapping NSTextField lays
        // itself ~2pt wider on each side than its usable text width.
        let textWidth = label.map { $0.alignmentRect(forFrame: $0.frame).width } ?? -1
        XCTAssertEqual(
            textWidth, UpdateCardView.notesMaxWidth, accuracy: 0.5,
            "the notes text wraps at \(textWidth)pt but notesMaxWidth is "
                + "\(UpdateCardView.notesMaxWidth)pt — the wrap column and the exposed budget disagree")
    }

    // MARK: - Bullet parsing

    func test_bullets_stripsDashAndAsteriskMarkers() {
        XCTAssertEqual(
            ZenUpdateDriver.bullets(from: "- Faster startup\n* Fixes the reorder bug"),
            ["Faster startup", "Fixes the reorder bug"])
    }

    func test_bullets_dropsBlankLines() {
        XCTAssertEqual(
            ZenUpdateDriver.bullets(from: "- one\n\n  \n- two"),
            ["one", "two"])
    }

    func test_bullets_keepsUnmarkedNonEmptyLines() {
        XCTAssertEqual(ZenUpdateDriver.bullets(from: "A plain line"), ["A plain line"])
    }

    func test_bullets_capsAtSix() {
        let many = (1...10).map { "- item \($0)" }.joined(separator: "\n")
        XCTAssertEqual(ZenUpdateDriver.bullets(from: many).count, 6)
    }

    func test_bullets_nilDescription_isEmpty() {
        XCTAssertEqual(ZenUpdateDriver.bullets(from: nil), [])
    }

    // MARK: - Helpers

    private func firstTextField(in view: NSView, where match: (String) -> Bool) -> NSTextField? {
        for sub in view.subviews {
            if let field = sub as? NSTextField, match(field.stringValue) { return field }
            if let found = firstTextField(in: sub, where: match) { return found }
        }
        return nil
    }
}
