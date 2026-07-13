import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the `SettingsFormSection` numeric commit pipeline (ZEN-104): clamp/range
/// validation, blank-stage-vs-debounce, integer rounding, and Return/blur early-commit. A
/// regression here writes garbage into the config file that every window then hot-reloads, so this
/// drives real form rows and asserts what actually landed in the config file.
///
/// The whole write→reload pipeline is rooted at `ConfigLoader.defaultRoot`; the tests point that
/// at a temp dir through the `defaultRootOverrideForTesting` seam so they never touch the real
/// config (an env-based redirect is unreliable — `ProcessInfo.environment` caches).
final class SettingsFormCommitTests: XCTestCase {
    private var tempRoot: URL!
    /// The section + host window are retained for the test's lifetime: the row's `onChange`
    /// captures the section `[weak self]`, so if the section deallocated the write would silently
    /// no-op (guard let self else return) and the commit would never fire.
    private var section: SettingsFormSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()  // GeneralConfig.current now reflects the empty temp root (= builtIn)
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()  // restore the process's real config state
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    /// Mount a section in a host window (both retained) and return its single numeric field,
    /// reached by walking the live view tree.
    private func mountField(_ section: SettingsFormSection) -> FieldBox {
        self.section = section
        let detail = section.makeDetailView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        self.hostWindow = window
        window.contentView?.addSubview(detail)
        detail.frame = window.contentView!.bounds
        func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }
        return descendants(of: detail).compactMap { $0 as? FieldBox }.first { $0.field.isEditable }!
    }

    /// Read the sandboxed config file straight from the root the writer used, so the read path
    /// can't drift from the write path.
    private func configText() -> String {
        (try? String(
            contentsOf: ConfigLoader.defaultRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    }

    // MARK: font-size (CGFloat, range 6…72)

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
        box.onEndEditing?()  // blur flushes the debounce immediately
        XCTAssertTrue(configText().contains("font-size = 50"), "got: \(configText())")
    }

    func test_outOfRangeValue_isRejectedAndNeverWritten() {
        let box = mountField(FontSizeSection())
        box.setText("100")  // above the 6…72 range
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
        box.onChange?()  // stages the removal without live-applying mid-edit
        box.onEndEditing?()  // blur commits the blank → key removed
        XCTAssertFalse(configText().contains("font-size"), "blank field must remove the key (→ default)")
    }

    func test_validValue_commitsAfterDebounceWithoutBlur() {
        let box = mountField(FontSizeSection())
        box.setText("40")
        box.onChange?()  // schedules the debounced apply; no blur
        // Wait on the observable outcome (the file content), not a fixed delay tied to `applyDelay`.
        let committed = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                self?.configText().contains("font-size = 40") ?? false
            }, object: nil)
        wait(for: [committed], timeout: 2)
        XCTAssertTrue(configText().contains("font-size = 40"), "debounce should commit; got: \(configText())")
    }

    // MARK: cursor-thickness (integer key, range 1…12)

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
        box.setText("5.7")  // valid (in 1…12), but an integer key must round it
        box.onChange?()
        box.onEndEditing?()
        XCTAssertTrue(configText().contains("cursor-thickness = 6"), "got: \(configText())")
        XCTAssertFalse(configText().contains("5.7"))
    }
}
