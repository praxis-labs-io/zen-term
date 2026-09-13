import AppKit
import XCTest

@testable import ZenTerm

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
        let box = box("line one\nline two", caret: 4)
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
        let box = box(text, caret: 4)
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

    func test_placeholder_isAnnouncedToVoiceOver() {
        let box = TextAreaBox(placeholder: "What went wrong")

        XCTAssertEqual(
            box.textView.accessibilityPlaceholderValue() as? String, "What went wrong",
            "a placeholder painted in draw is invisible to the accessibility tree on its own")
    }

    func test_aFocusedFieldsCaret_comesFromTheThemeNotTheSystemAccent() throws {
        let box = FieldBox(placeholder: "Title")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            box.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        content.layoutSubtreeIfNeeded()

        window.makeFirstResponder(box.field)

        let editor = try XCTUnwrap(box.field.currentEditor() as? NSTextView, "the field has to be editing")
        XCTAssertEqual(
            editor.insertionPointColor, Theme.current.chrome.foreground.nsColor,
            "the caret is the theme's ink, not whatever accent the OS is set to")
    }
}
