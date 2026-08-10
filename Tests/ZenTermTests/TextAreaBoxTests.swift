import AppKit
import XCTest

@testable import ZenTerm

/// Unit tests for the multiline input's keyboard-boundary handling, driven through the real
/// `doCommandBy` path (not the focus-ring closures), so the caret-position logic that decides whether
/// an arrow leaves the field is actually exercised.
final class TextAreaBoxTests: WindowTestCase {
    private func box(_ text: String, caret: Int) -> TextAreaBox {
        let box = TextAreaBox(placeholder: "x")
        box.setText(text)
        box.textView.setSelectedRange(NSRange(location: caret, length: 0))
        return box
    }

    @discardableResult
    private func command(_ box: TextAreaBox, _ selector: Selector) -> Bool {
        box.textView(box.textView, doCommandBy: selector)
    }

    func test_up_leavesFromTheStart_butMovesTheCaretMidText() {
        let box = box("line one\nline two", caret: 4)  // mid first line
        var left = 0
        box.onArrowUp = { left += 1 }

        XCTAssertFalse(command(box, #selector(NSResponder.moveUp(_:))), "mid-text Up moves the caret")
        XCTAssertEqual(left, 0)

        box.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(command(box, #selector(NSResponder.moveUp(_:))), "Up from the start leaves")
        XCTAssertEqual(left, 1)
    }

    func test_down_leavesFromTheEnd_butMovesTheCaretMidText() {
        let text = "line one\nline two"
        let box = box(text, caret: 4)  // mid text
        var left = 0
        box.onArrowDown = { left += 1 }

        XCTAssertFalse(command(box, #selector(NSResponder.moveDown(_:))), "mid-text Down moves the caret")
        XCTAssertEqual(left, 0)

        box.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        XCTAssertTrue(command(box, #selector(NSResponder.moveDown(_:))), "Down from the end leaves")
        XCTAssertEqual(left, 1)
    }

    func test_tab_leaves() {
        let box = box("anything", caret: 0)
        var tabbed = 0
        box.onTab = { tabbed += 1 }
        XCTAssertTrue(command(box, #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(tabbed, 1)
    }

    // MARK: placeholder placement

    /// The placeholder used to be a label laid out over the text view on its own insets, so it sat
    /// 4pt left of where typing starts and the caret landed on its first letter. It now draws at the
    /// origin the text view's own first glyph takes.
    ///
    /// The expected origin comes from the layout manager's rect for a real glyph, which is a different
    /// derivation than the view's (container origin plus line fragment padding), so this measures
    /// agreement rather than restating one side.
    func test_placeholder_drawsWhereTheFirstGlyphLands() throws {
        let box = TextAreaBox(placeholder: "What went wrong")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            box.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
        ])
        window.contentView?.layoutSubtreeIfNeeded()

        let view = box.textView
        box.setText("W")
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        let glyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
        box.setText("")

        let origin = view.placeholderOrigin
        XCTAssertEqual(
            origin.x, glyph.minX + view.textContainerOrigin.x, accuracy: 0.5,
            "the placeholder starts where a typed character starts")
        XCTAssertEqual(
            origin.y, glyph.minY + view.textContainerOrigin.y, accuracy: 0.5,
            "and on the same line")
    }

    /// The multiline box sits directly under a `FieldBox` in the Report an Issue form, so their text
    /// has to start on the same line. It didn't: the field's text lands 7pt in, the text area's 14 (a
    /// 6pt scroll inset, a 3pt container inset, and the layout manager's 5pt line fragment padding,
    /// which no constraint in the file mentions).
    func test_textStartsAtTheSameInsetAsAFieldBox() throws {
        let field = FieldBox(placeholder: "Title")
        let area = TextAreaBox(placeholder: "What went wrong")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 260),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(field)
        content.addSubview(area)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            field.topAnchor.constraint(equalTo: content.topAnchor),
            area.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            area.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            area.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
        ])
        content.layoutSubtreeIfNeeded()

        let inner = field.field
        let title = try XCTUnwrap(inner.cell?.titleRect(forBounds: inner.bounds))
        let fieldTextX = inner.convert(NSPoint(x: title.minX, y: 0), to: field).x
        let areaTextX = area.textView.convert(area.textView.placeholderOrigin, to: area).x

        XCTAssertEqual(
            areaTextX, fieldTextX, accuracy: 0.5,
            "the text area's text starts \(areaTextX)pt in, the field's \(fieldTextX)pt")
    }

    /// The placeholder moved from a label into `draw`, which VoiceOver cannot see. The text view has to
    /// carry it as its accessibility placeholder instead, or the one text area in the app is unlabeled.
    func test_placeholder_isAnnouncedToVoiceOver() {
        let box = TextAreaBox(placeholder: "What went wrong")

        XCTAssertEqual(
            box.textView.accessibilityPlaceholderValue() as? String, "What went wrong",
            "a placeholder painted in draw is invisible to the accessibility tree on its own")
    }
}
