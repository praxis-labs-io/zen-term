import AppKit
import XCTest

@testable import ZenTerm

final class SettingsFormCommitTests: WindowTestCase {
    private var tempRoot: URL!
    /// Retained: the row's `onChange` captures the section weakly.
    private var section: SettingsFormSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func mountDetail(_ section: SettingsFormSection) -> NSView {
        self.section = section
        let detail = section.makeDetailView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        self.hostWindow = window
        window.contentView?.addSubview(detail)
        detail.frame = window.contentView!.bounds
        return detail
    }

    private func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }
    private func editableFields(in detail: NSView) -> [FieldBox] {
        descendants(of: detail).compactMap { $0 as? FieldBox }.filter { $0.field.isEditable }
    }
    private func layoutRows(in detail: NSView) -> [LayoutRow] {
        descendants(of: detail).compactMap { $0 as? LayoutRow }
    }

    private func mountField(_ section: SettingsFormSection) -> FieldBox {
        editableFields(in: mountDetail(section)).first!
    }

    private func configText() -> String {
        (try? String(
            contentsOf: ConfigLoader.defaultRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    }

    private final class FontSizeSection: SettingsFormSection {
        override var navTitle: String { "Appearance" }
        override func populate() {
            addGroup("Text") {
                addNumericRow(
                    key: "font-size", caption: "Font Size", blurb: "", range: 6...72,
                    read: { $0.fontSize })
            }
        }
    }

    func test_validValue_commitsOnBlur() {
        let box = mountField(FontSizeSection())
        box.setText("50")
        box.onChange?()
        box.onEndEditing?()
        XCTAssertTrue(configText().contains("font-size = 50"), "got: \(configText())")
    }

    func test_outOfRangeValue_isRejectedAndNeverWritten() {
        let box = mountField(FontSizeSection())
        box.setText("100")
        box.onChange?()
        box.onEndEditing?()
        XCTAssertFalse(configText().contains("font-size"), "out-of-range value must not be written")
    }

    func test_junkValue_isRejectedAndNeverWritten() {
        let box = mountField(FontSizeSection())
        box.setText("abc")
        box.onChange?()
        box.onEndEditing?()
        XCTAssertFalse(configText().contains("font-size"), "non-numeric text must not be written")
    }

    func test_blankAfterAValue_removesTheKey() {
        let box = mountField(FontSizeSection())
        box.setText("50")
        box.onChange?()
        box.onEndEditing?()
        XCTAssertTrue(configText().contains("font-size = 50"))

        box.setText("")
        box.onChange?()
        box.onEndEditing?()
        XCTAssertFalse(configText().contains("font-size"), "blank field must remove the key (→ default)")
    }

    func test_validValue_commitsAfterDebounceWithoutBlur() {
        let box = mountField(FontSizeSection())
        box.setText("40")
        box.onChange?()
        let committed = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                self?.configText().contains("font-size = 40") ?? false
            }, object: nil)
        wait(for: [committed], timeout: 2)
        XCTAssertTrue(configText().contains("font-size = 40"), "debounce should commit; got: \(configText())")
    }

    private final class ThicknessSection: SettingsFormSection {
        override var navTitle: String { "Cursor" }
        override func populate() {
            addGroup("Cursor") {
                addNumericRow(
                    key: "cursor-thickness", caption: "Thickness", blurb: "", range: 1...12,
                    read: { CGFloat($0.cursorThickness) }, integer: true)
            }
        }
    }

    func test_integerKey_roundsFractionalInputOnCommit() {
        let box = mountField(ThicknessSection())
        box.setText("5.7")
        box.onChange?()
        box.onEndEditing?()
        XCTAssertTrue(configText().contains("cursor-thickness = 6"), "got: \(configText())")
        XCTAssertFalse(configText().contains("5.7"))
    }

    private final class TwoNumericSection: SettingsFormSection {
        override var navTitle: String { "Terminal" }
        override func populate() {
            addGroup("Nums") {
                addNumericRow(
                    key: "font-size", caption: "Font Size", blurb: "", range: 6...72, read: { $0.fontSize })
                addNumericRow(
                    key: "cursor-thickness", caption: "Thickness", blurb: "", range: 1...12,
                    read: { CGFloat($0.cursorThickness) }, integer: true)
            }
        }
    }

    func test_liveRangeError_survivesAnUnrelatedRowsCommit() {
        let detail = mountDetail(TwoNumericSection())
        let fields = editableFields(in: detail)
        fields[0].setText("3")
        fields[0].onChange?()
        fields[1].setText("5")
        fields[1].onChange?()
        fields[1].onEndEditing?()
        let messages = layoutRows(in: detail).compactMap { $0.renderedMessageForTesting }
        XCTAssertEqual(messages.count, 1, "only the font-size row still shows a message; got: \(messages)")
        XCTAssertTrue(messages.first?.contains("Enter a number") == true, "range error was wiped: \(messages)")
    }
}
