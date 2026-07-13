import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the Tools settings section (ZEN-109): mount the real section over a
/// sandboxed config, assert it renders a row per configured float, that add / edit route out
/// through `onEditFloat`, and that remove writes the config and drops the row. The write→reload
/// roundtrip is sandboxed via `ConfigLoader.defaultRootOverrideForTesting`.
final class SettingsToolsSectionTests: XCTestCase {
    /// Records the float `onEditFloat` was invoked with (`nil` = add).
    private final class EditSink {
        var calls: [ToolFloat?] = []
    }

    private var tempRoot: URL!
    private var window: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        window = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    // MARK: harness

    private func seed(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @discardableResult
    private func mount(_ section: SettingsToolsSection) -> NSView {
        let detail = section.makeDetailView()
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(detail)
        detail.frame = win.contentView!.bounds
        window = win
        return detail
    }

    private func rows(in view: NSView) -> [ToolFloatRow] {
        descendants(of: view).compactMap { $0 as? ToolFloatRow }
    }

    private let twoFloats = """
        float = id:dev key:cmd+shift+d command:vim
        float = id:top key:cmd+shift+t command:htop
        """

    // MARK: tests

    func test_rendersRowPerConfiguredFloat() throws {
        try seed(twoFloats)
        let detail = mount(SettingsToolsSection())
        XCTAssertEqual(rows(in: detail).map(\.float.id), ["dev", "top"])
    }

    func test_emptyConfig_showsOnlyAddButtonStop() throws {
        try seed("")
        let section = SettingsToolsSection()
        let detail = mount(section)
        XCTAssertTrue(rows(in: detail).isEmpty)
        XCTAssertEqual(section.detailStops().count, 1, "empty state exposes only the add button")
        XCTAssertTrue(section.detailStops().first is AppButton)
    }

    func test_addButton_invokesOnEditFloatWithNil() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        let sink = EditSink()
        section.onEditFloat = { sink.calls.append($0) }
        _ = mount(section)

        (section.detailStops().last as? AppButton)?.onTap()

        XCTAssertEqual(sink.calls.count, 1)
        XCTAssertNil(sink.calls.first ?? nil, "the add button adds a new float (nil)")
    }

    func test_rowActivate_invokesOnEditFloatWithThatFloat() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        let sink = EditSink()
        section.onEditFloat = { sink.calls.append($0) }
        let detail = mount(section)

        rows(in: detail).first { $0.float.id == "top" }?.onActivate?()

        XCTAssertEqual(sink.calls.first??.id, "top")
    }

    func test_remove_writesConfigAndDropsRow() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        let detail = mount(section)
        XCTAssertEqual(rows(in: detail).count, 2)

        rows(in: detail).first { $0.float.id == "dev" }?.onRemove?()

        XCTAssertEqual(GeneralConfig.current.floats.map(\.id), ["top"], "the removed float is gone from config")
        XCTAssertEqual(rows(in: detail).map(\.float.id), ["top"], "the row list rebuilds without it")
    }
}
