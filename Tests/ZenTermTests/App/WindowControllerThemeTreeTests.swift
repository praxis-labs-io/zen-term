import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WindowControllerThemeTreeTests: WindowTestCase {
    private var originalTheme: AppTheme!
    private var originalConfig: GeneralConfig!
    private var originalOverride: (() -> TerminalSurface)?
    private var tempRoots: [URL] = []
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        originalTheme = Theme.current
        originalConfig = GeneralConfig.current
        originalOverride = TerminalSurfaceFactory.makeOverride
        GeneralConfig.setCurrentForTesting(.builtIn)
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        Theme.setCurrentForTesting(originalTheme)
        GeneralConfig.setCurrentForTesting(originalConfig)
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
        try super.tearDownWithError()
    }

    private final class CountingProbe: NSView, ThemeReapplying {
        var count = 0
        func reapplyTheme() { count += 1 }
    }

    private final class RebuildingParent: NSView, ThemeReapplying {
        var child = CountingProbe()
        var retired: [CountingProbe] = []
        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(child)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        func reapplyTheme() {
            retired.append(child)
            child.removeFromSuperview()
            child = CountingProbe()
            addSubview(child)
        }
    }

    private func makeAlternateTheme() throws -> AppTheme {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-themetree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        try """
        background = #010101
        foreground = #fefefe
        palette = 1=#ff0000
        palette = 5=#00ff00
        palette = \(AccentSlot.themeDefault.ansiIndex)=#00ffff
        """.write(to: dir.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadAppTheme(configRoot: dir, general: .builtIn)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()
        return controller
    }

    private func post(_ change: ConfigChange?) {
        let info = change.map { [ConfigChange.userInfoKey: $0] }
        NotificationCenter.default.post(name: .configDidChange, object: nil, userInfo: info)
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    private func fill(_ button: AppButton) -> CGColor? { button.layer?.backgroundColor }

    func test_themeChange_recolorsANestedButtonAndAHiddenArrangedOne() throws {
        let controller = makeController()
        let nested = AppButton(title: "Nested", variant: .primary)
        let hidden = AppButton(title: "Hidden", variant: .primary)
        let inner = NSStackView(views: [nested])
        let outer = NSStackView(views: [inner, hidden])
        hidden.isHidden = true
        controller.window.contentView!.addSubview(outer)
        let nestedBefore = fill(nested)
        let hiddenBefore = fill(hidden)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        post(.theme)

        XCTAssertNotEqual(nestedBefore, fill(nested), "a nested button kept the old theme")
        XCTAssertNotEqual(hiddenBefore, fill(hidden), "a hidden arranged button kept the old theme")
    }

    func test_walk_skipsAChildItsParentRebuiltAndCallsASiblingOnce() {
        let root = NSView()
        let parent = RebuildingParent(frame: .zero)
        let sibling = CountingProbe()
        root.addSubview(parent)
        root.addSubview(sibling)
        let firstChild = parent.child

        root.reapplyThemeTree()

        XCTAssertEqual(firstChild.count, 0, "the walk recolored a view its parent had already replaced")
        XCTAssertEqual(parent.child.count, 0, "the walk recolored a view built after the walk began")
        XCTAssertEqual(sibling.count, 1)
    }

    func test_allChange_walksEachSubtreeOnce() throws {
        let controller = makeController()
        let root = controller.window.contentView!
        let hostProbe = CountingProbe()
        let dockProbe = CountingProbe()
        let rootProbe = CountingProbe()
        let host = try XCTUnwrap(descendants(of: root).compactMap { $0 as? PanelHostView }.first)
        let dock = try XCTUnwrap(descendants(of: root).compactMap { $0 as? ToggleDock }.first)
        host.addSubview(hostProbe)
        dock.addSubview(dockProbe)
        root.addSubview(rootProbe)

        post(nil)

        XCTAssertEqual(rootProbe.count, 1)
        XCTAssertEqual(hostProbe.count, 1, "an untagged reload walked the pane host again")
        XCTAssertEqual(dockProbe.count, 1, "an untagged reload walked the dock again")
    }

    func test_themeChange_reachesAnInactiveTabsHostBeforeYouSwitchBack() throws {
        Motion.isReduceMotionEnabled = { true }
        let controller = makeController()
        let host = try XCTUnwrap(
            descendants(of: controller.window.contentView!).compactMap { $0 as? PanelHostView }.first)
        let before = try XCTUnwrap(host.borderForTesting.color)

        controller.handle(.newTab)
        XCTAssertNil(host.window, "premise: the first tab's host left the window")
        Theme.setCurrentForTesting(try makeAlternateTheme())
        post(.theme)
        controller.handle(.selectTab(1))

        XCTAssertNotNil(host.window)
        XCTAssertNotEqual(before, host.borderForTesting.color, "the inactive tab came back in the old theme")
    }
}
