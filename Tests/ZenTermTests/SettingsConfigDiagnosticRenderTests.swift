import AppKit
import XCTest

@testable import ZenTerm

final class SettingsConfigDiagnosticRenderTests: WindowTestCase {
    private var tempRoot: URL!
    private var section: SettingsSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-diagnostic-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func loadConfig(_ text: String) {
        try? text.write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
    }

    private func mount(_ section: SettingsSection) -> [NSView] {
        self.section = section
        let detail = section.makeDetailView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.borderless], backing: .buffered, defer: false)
        self.hostWindow = window
        window.contentView?.addSubview(detail)
        detail.frame = window.contentView!.bounds
        func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }
        return descendants(of: detail)
    }

    private func rowMessages(_ views: [NSView]) -> [String] {
        views.compactMap { ($0 as? LayoutRow)?.renderedMessageForTesting }
    }

    func test_clampedScalar_showsOnTheTerminalRow() {
        loadConfig("font-size = 200\n")
        let messages = rowMessages(mount(SettingsTerminalSection()))
        XCTAssertEqual(messages, ["font-size = 200 is out of range. Using 32."])
    }

    func test_invalidEnum_showsOnTheTerminalRow() {
        loadConfig("cursor-style = beam\n")
        let messages = rowMessages(mount(SettingsTerminalSection()))
        XCTAssertEqual(messages, ["cursor-style = beam isn't valid (block, bar, or underline). Using the default."])
    }

    func test_reduceMotion_showsOnTheAppearanceRow() {
        loadConfig("reduce-motion = maybe\n")
        let messages = rowMessages(mount(SettingsAppearanceSection()))
        XCTAssertEqual(messages, ["reduce-motion = maybe isn't valid (system, on, or off). Using the default."])
    }

    func test_unknownToolbarButtonSlug_showsOnTheAppearanceRow() {
        loadConfig("hide-toolbar-buttons = split-h,zoom\n")
        let expected = ToolbarButton.allCases.map(\.rawValue).joined(separator: ", ")
        let messages = rowMessages(mount(SettingsAppearanceSection()))
        XCTAssertEqual(
            messages,
            ["hide-toolbar-buttons: zoom isn't valid (\(expected)). Ignoring it; the rest still applies."])
    }

    func test_cleanConfig_showsNoRowMessages() {
        loadConfig("font-size = 16\ncursor-style = bar\n")
        XCTAssertTrue(rowMessages(mount(SettingsTerminalSection())).isEmpty)
    }

    func test_droppedFloat_showsTheToolsNotice() {
        loadConfig("float = title:Notes key:cmd+shift+n\n")
        let notices = mount(SettingsToolsSection())
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .filter { $0.contains("Ignoring this tool float") }
        XCTAssertEqual(notices, ["Notes is missing command:. Ignoring this tool float."])
    }

    func test_cleanConfig_showsNoToolsNotice() {
        loadConfig("float = title:Notes command:notes key:cmd+shift+n\n")
        let notices = mount(SettingsToolsSection())
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .filter { $0.contains("Ignoring this tool float") }
        XCTAssertTrue(notices.isEmpty)
    }

    private func toolRowMessages(_ views: [NSView]) -> [String] {
        views.compactMap { ($0 as? ToolFloatRow)?.renderedMessageForTesting }
    }

    func test_survivingFloatWithBadField_showsOnItsToolsRow() {
        loadConfig("float = title:Notes command:notes key:cmd+shift+n width:big\n")
        let views = mount(SettingsToolsSection())
        XCTAssertEqual(toolRowMessages(views), ["Notes: width:big isn't valid. Using 0.85."])
        let notices = views.compactMap { ($0 as? NSTextField)?.stringValue }
            .filter { $0.contains("Ignoring this tool float") }
        XCTAssertTrue(notices.isEmpty, "a surviving float belongs on its row, not the dropped-line notice")
    }

    func test_cleanFloat_showsNoRowMessage() {
        loadConfig("float = title:Notes command:notes key:cmd+shift+n\n")
        XCTAssertTrue(toolRowMessages(mount(SettingsToolsSection())).isEmpty)
    }

    func test_landing_mapsEachScopeToItsSection() {
        func landing(_ scope: ConfigDiagnostic.Scope) -> String? {
            WindowController.settingsLandingNavTitleForTesting(for: scope)
        }
        XCTAssertEqual(landing(.setting(key: "font-size")), "Terminal")
        XCTAssertEqual(landing(.setting(key: "cursor-style")), "Terminal")
        XCTAssertEqual(landing(.setting(key: "background-alpha")), "Terminal")
        XCTAssertEqual(landing(.setting(key: "reduce-motion")), "Appearance")
        XCTAssertEqual(landing(.setting(key: "backdrop-alpha")), "Appearance")
        XCTAssertEqual(landing(.setting(key: "agent-notifications")), "General")
        XCTAssertEqual(landing(.keybind(.splitVertical)), "Shortcuts")
        XCTAssertEqual(landing(.keybindLine), "Shortcuts")
        XCTAssertEqual(landing(.toolFloat(label: "x")), "Tools")
        XCTAssertNil(landing(.setting(key: "debug")), "a key with no form row lands on the nav")
    }
}
