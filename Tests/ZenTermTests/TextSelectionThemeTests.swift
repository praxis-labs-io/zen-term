import AppKit
import XCTest

@testable import ZenTerm

final class TextSelectionThemeTests: WindowTestCase {
    private final class KeyedWindow: NSWindow {
        var isKey = true
        private lazy var editor = ChromeTextView.makeFieldEditor()

        override var isKeyWindow: Bool { isKey }

        override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
            object is NSTextField ? editor : super.fieldEditor(createFlag, for: object)
        }
    }

    private static let spacedText = "a" + String(repeating: " ", count: 24) + "b"

    private var originalTheme = Theme.builtIn

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalTheme = Theme.current
    }

    override func tearDownWithError() throws {
        Theme.setCurrentForTesting(originalTheme)
        try super.tearDownWithError()
    }

    private func lightTheme(accent: AccentSlot) throws -> AppTheme {
        let url = try XCTUnwrap(ThemeCatalog.bundledURL(for: "github-light-default"))
        let terminal = GhosttyThemeParser.parse(
            try String(contentsOf: url, encoding: .utf8), fontName: "Menlo", fontSize: 12,
            fallback: Theme.rosePineZen)
        return AppTheme(terminal: terminal, accent: accent)
    }

    private func themes() throws -> [(theme: AppTheme, appearance: NSAppearance.Name)] {
        [
            (try lightTheme(accent: .red), .darkAqua),
            (AppTheme(terminal: Theme.builtIn.terminal, accent: .red), .aqua),
        ]
    }

    private func makeWindow(appearance: NSAppearance.Name) -> KeyedWindow {
        let window = KeyedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 260), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        window.contentView = content
        return window
    }

    private func mount(_ views: [NSView], in window: NSWindow) throws {
        let content = try XCTUnwrap(window.contentView)
        var top = content.topAnchor
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                view.widthAnchor.constraint(equalToConstant: 300),
                view.topAnchor.constraint(equalTo: top, constant: 10),
            ])
            top = view.bottomAnchor
        }
        content.layoutSubtreeIfNeeded()
    }

    private func swatch(_ selection: NSColor) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = Theme.current.chrome.fill(.rest).cgColor
        box.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = selection.cgColor
        fill.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(fill)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            fill.topAnchor.constraint(equalTo: box.topAnchor),
            fill.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    private func pixel(at point: NSPoint, in view: NSView) throws -> NSColor {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / view.bounds.height
        let y = view.isFlipped ? point.y : view.bounds.height - point.y
        let color = try XCTUnwrap(rep.colorAt(x: Int(point.x * scaleX), y: Int(y * scaleY)))
        return try XCTUnwrap(color.usingColorSpace(.sRGB))
    }

    private func distance(_ lhs: NSColor, _ rhs: NSColor) throws -> CGFloat {
        let (a, b) = (try XCTUnwrap(lhs.usingColorSpace(.sRGB)), try XCTUnwrap(rhs.usingColorSpace(.sRGB)))
        return [
            a.redComponent - b.redComponent, a.greenComponent - b.greenComponent, a.blueComponent - b.blueComponent,
        ].map { $0 * $0 }.reduce(0, +).squareRoot()
    }

    private func spacesCenter(of textView: NSTextView, in view: NSView) throws -> NSPoint {
        let layout = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: 2, length: 20), actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        let converted = textView.convert(rect, to: view)
        return NSPoint(x: converted.midX, y: converted.midY)
    }

    private func swatchCenter(_ swatch: NSView, in view: NSView) -> NSPoint {
        let frame = swatch.convert(swatch.bounds, to: view)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    private func assertSelection(
        in textView: NSTextView, of window: NSWindow, matches reference: NSView, unlike other: NSView,
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let content = try XCTUnwrap(window.contentView)
        let drawn = try pixel(at: try spacesCenter(of: textView, in: content), in: content)
        let wanted = try pixel(at: swatchCenter(reference, in: content), in: content)
        let unwanted = try pixel(at: swatchCenter(other, in: content), in: content)
        XCTAssertGreaterThan(
            try distance(wanted, unwanted), 0.04, "\(message): the two states have to be told apart", file: file,
            line: line)
        XCTAssertLessThan(
            try distance(drawn, wanted), 0.02, "\(message): drew \(drawn), wanted \(wanted)", file: file, line: line)
    }

    private var focusedTint: NSColor {
        Theme.current.chrome.tint(Theme.current.chrome.accent, alpha: ChromeTheme.badgeTint)
    }

    private var unfocusedFill: NSColor { Theme.current.chrome.fill(.active) }

    private func selectedField(in window: KeyedWindow) throws -> (FieldBox, NSTextView) {
        let box = FieldBox(placeholder: "Name")
        box.setText(Self.spacedText)
        let (tinted, neutral) = (swatch(focusedTint), swatch(unfocusedFill))
        try mount([box, tinted, neutral], in: window)
        XCTAssertTrue(window.makeFirstResponder(box.field))
        let editor = try XCTUnwrap(box.field.currentEditor() as? NSTextView, "the field has to be editing")
        editor.selectAll(nil)
        return (box, editor)
    }

    func test_focusedFieldSelection_paintsTheAccentTint() throws {
        for (theme, appearance) in try themes() {
            Theme.setCurrentForTesting(theme)
            let window = makeWindow(appearance: appearance)
            let (_, editor) = try selectedField(in: window)
            let content = try XCTUnwrap(window.contentView)
            try assertSelection(
                in: editor, of: window, matches: content.subviews[1], unlike: content.subviews[2],
                "focused field under \(appearance.rawValue)")
            window.close()
        }
    }

    func test_fieldSelection_whenTheWindowIsNotKey_paintsTheNeutralFill() throws {
        for (theme, appearance) in try themes() {
            Theme.setCurrentForTesting(theme)
            let window = makeWindow(appearance: appearance)
            let (_, editor) = try selectedField(in: window)
            window.isKey = false
            let content = try XCTUnwrap(window.contentView)
            try assertSelection(
                in: editor, of: window, matches: content.subviews[2], unlike: content.subviews[1],
                "field in a window that isn't key under \(appearance.rawValue)")
            window.close()
        }
    }

    func test_textAreaSelection_tintsWhenFocused_andGoesNeutralWhenFocusLeaves() throws {
        for (theme, appearance) in try themes() {
            Theme.setCurrentForTesting(theme)
            let window = makeWindow(appearance: appearance)
            let area = TextAreaBox(placeholder: "Note", minHeight: 60)
            area.setText(Self.spacedText)
            let field = FieldBox(placeholder: "Name")
            let (tinted, neutral) = (swatch(focusedTint), swatch(unfocusedFill))
            try mount([area, field, tinted, neutral], in: window)

            XCTAssertTrue(window.makeFirstResponder(area.textView))
            area.textView.selectAll(nil)
            try assertSelection(
                in: area.textView, of: window, matches: tinted, unlike: neutral,
                "focused text area under \(appearance.rawValue)")

            XCTAssertTrue(window.makeFirstResponder(field.field))
            try assertSelection(
                in: area.textView, of: window, matches: neutral, unlike: tinted,
                "text area after focus left under \(appearance.rawValue)")
            window.close()
        }
    }

    func test_hostWindow_editsFieldsWithTheThemedEditor() throws {
        let window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400))
        let box = FieldBox(placeholder: "Name")
        try mount([box], in: window)

        XCTAssertTrue(window.makeFirstResponder(box.field))

        XCTAssertTrue(box.field.currentEditor() is ChromeTextView, "a field edits with AppKit's untinted editor")
    }

    func test_hostWindow_selectsInASelectableLabelWithTheThemedEditor() throws {
        let window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400))
        let label = NSTextField(wrappingLabelWithString: "Connection refused by the host")
        try mount([label], in: window)
        XCTAssertTrue(label.isSelectable)

        label.selectText(nil)

        let editor = try XCTUnwrap(
            window.firstResponder as? ChromeTextView, "a selectable label selects with AppKit's untinted editor")
        XCTAssertEqual(editor.string, label.stringValue, "the click did not start a selection in the label")
        XCTAssertEqual(editor.selectedTextAttributes[.backgroundColor] as? NSColor, focusedTint)
    }

    func test_themeSwitch_whileEditing_retintsTheSelection() throws {
        Theme.setCurrentForTesting(Theme.builtIn)
        let window = makeWindow(appearance: .darkAqua)
        let (box, editor) = try selectedField(in: window)
        let area = TextAreaBox(placeholder: "Note")
        try mount([area], in: window)

        Theme.setCurrentForTesting(try lightTheme(accent: .magenta))
        box.reapplyTheme()
        area.reapplyTheme()

        for (name, view) in [("field", editor), ("text area", area.textView)] {
            XCTAssertEqual(
                view.selectedTextAttributes[.backgroundColor] as? NSColor, focusedTint,
                "the \(name) kept the old theme's selection")
            XCTAssertEqual(
                view.insertionPointColor, Theme.current.chrome.ink(.normal), "the \(name) kept the old caret")
        }
    }
}
