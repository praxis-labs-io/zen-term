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
