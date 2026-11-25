import AppKit
import XCTest

@testable import ZenTerm

final class SingleLineFieldTests: WindowTestCase {
    private func editedLineCount(of field: NSTextField, in window: NSWindow) throws -> Int {
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "the field has to be editing")
        editor.insertText(
            String(repeating: "~/projects/zen-term/", count: 12),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        let layout = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        layout.ensureLayout(for: container)
        var lines = 0
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            var line = NSRange()
            layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
            lines += 1
            glyph = NSMaxRange(line)
        }
        return lines
    }

    private func hostWindow() -> HostWindow {
        let window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func test_aLongValueInAFieldBox_staysOnOneLineWhileEditing() throws {
        let window = hostWindow()
        let box = FieldBox(placeholder: "Folder")
        box.translatesAutoresizingMaskIntoConstraints = false
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            box.widthAnchor.constraint(equalToConstant: 160),
            box.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
        ])
        content.layoutSubtreeIfNeeded()

        XCTAssertEqual(try editedLineCount(of: box.field, in: window), 1)
        window.orderOut(nil)
    }
}

final class HiddenFieldBoxTests: WindowTestCase {
    func test_aFieldBoxHidingItsText_typesSecurely_ringsOnFocus_andSubmitsOnReturn() throws {
        let window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let box = FieldBox(placeholder: "Password", hidesText: true)
        var entered = 0
        box.onEnter = { entered += 1 }
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            box.widthAnchor.constraint(equalToConstant: 160),
            box.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
        ])
        content.layoutSubtreeIfNeeded()

        XCTAssertTrue(window.makeFirstResponder(box.field))
        XCTAssertEqual(box.layer?.borderColor, Theme.current.chrome.focusRing.cgColor)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.delegate === box.field)
        XCTAssertTrue(box.field.cell is NSSecureTextFieldCell, "the field must be a secure one, not a plain one")
        editor.insertText("s3cret", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(box.text, "s3cret")
        XCTAssertEqual(entered, 1)
        box.reapplyTheme()
        XCTAssertEqual(box.layer?.borderColor, Theme.current.chrome.focusRing.cgColor, "a theme change keeps the ring")
        XCTAssertFalse(FieldBox(placeholder: "Name").field.cell is NSSecureTextFieldCell)
    }
}
