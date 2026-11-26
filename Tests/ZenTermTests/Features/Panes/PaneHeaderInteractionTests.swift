import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class PaneHeaderInteractionTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private let root = FileManager.default.temporaryDirectory
    private let jobs = ProgramJobs()

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        jobs.stopAll()
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), initialCWD: root)
        c.mountAndStart()
        controller = c
        return c
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func hosts(_ c: WindowController) -> [PanelHostView] {
        descendants(of: c.window.contentView!).compactMap { $0 as? PanelHostView }
    }

    private func paneHosts(_ c: WindowController) -> [PanelHostView] {
        hosts(c).filter { $0.header?.controlsForTesting.contains(.splitHorizontal) == true }
    }

    private func surface(of host: PanelHostView) -> RecordingSurface? {
        spawned.first { $0.view.isDescendant(of: host) }
    }

    private func click(_ control: PaneHeader.Control, on header: PaneHeader?, in window: NSWindow) throws {
        let button = try XCTUnwrap(header?.buttonForTesting(control), "no \(control) on this header")
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { button.mouseDown(with: event) } else { button.mouseUp(with: event) }
        }
    }

    func test_theHeaderNamesWhatRunsAndWhere_whileTheTabReadsTheTitle() throws {
        let c = makeWindow()
        let host = try XCTUnwrap(paneHosts(c).first)
        let surface = try XCTUnwrap(surface(of: host))
        let header = try XCTUnwrap(host.shownHeaderForTesting, "a lone pane wears a header too")
        surface.currentDirectory = root
        let path = PathDisplay.abbreviatingHome(root.path)

        surface.foregroundProcessGroupID = try runJob(["/bin/sleep", "60"])
        surface.title = "✳ Deploying staging"
        c.pollTitlesForTesting()

        XCTAssertEqual(header.nameForTesting, "sleep", "the header names the program")
        XCTAssertEqual(header.pathForTesting, path, "and where it runs")
        XCTAssertEqual(c.tabTitleForTesting(index: 0), "Deploying staging", "the tab reads its title, status dropped")

        surface.foregroundProcessGroupID = nil
        surface.title = root.path
        c.pollTitlesForTesting()

        XCTAssertEqual(header.nameForTesting, "shell")
        XCTAssertEqual(c.tabTitleForTesting(index: 0), root.lastPathComponent, "a tab never shows a full path")
    }

    private func runJob(_ arguments: [String]) throws -> pid_t {
        let job = Process()
        job.executableURL = URL(fileURLWithPath: arguments[0])
        job.arguments = Array(arguments.dropFirst())
        try job.run()
        addTeardownBlock { job.terminate() }
        return job.processIdentifier
    }

    func test_aHeaderButton_actsOnItsOwnPane_notTheFocusedOne() throws {
        let c = makeWindow()
        c.handle(.splitVertical)
        c.window.contentView?.layoutSubtreeIfNeeded()
        let focused = try XCTUnwrap(c.focusedPanelForTesting)
        let other = try XCTUnwrap(paneHosts(c).first { $0 !== focused })
        let otherSurface = try XCTUnwrap(surface(of: other))

        try click(.close, on: other.header, in: c.window)

        XCTAssertTrue(otherSurface.terminated, "the clicked pane closed")
        XCTAssertEqual(paneHosts(c).count, 1)
        XCTAssertIdentical(paneHosts(c).first, focused, "the pane that held focus is the one left")
    }

    func test_onlyThePaneWhereFocusSits_showsItsControlsAtRest() throws {
        let c = makeWindow()
        c.handle(.splitVertical)
        c.window.contentView?.layoutSubtreeIfNeeded()
        let focused = try XCTUnwrap(c.focusedPanelForTesting)
        let other = try XCTUnwrap(paneHosts(c).first { $0 !== focused })

        XCTAssertEqual(focused.header?.controlsShownForTesting, true)
        XCTAssertEqual(other.header?.controlsShownForTesting, false)
    }

    func test_aDrawer_wearsOneHeader_withFocusModeAndClose() throws {
        let c = makeWindow()
        c.handle(.toggleBottomDrawer)
        c.window.contentView?.layoutSubtreeIfNeeded()
        let drawer = try XCTUnwrap(hosts(c).first { !paneHosts(c).contains($0) })

        XCTAssertEqual(descendants(of: drawer).compactMap { $0 as? PaneHeader }.count, 1, "never two headers")
        XCTAssertEqual(drawer.shownHeaderForTesting?.visibleControlsForTesting, [.focusMode, .close])
        XCTAssertEqual(drawer.header?.controlsShownForTesting, true, "focus lands in a drawer as it opens")
    }

    func test_aDrawersPath_followsItsFolderTheMomentItChanges() throws {
        let c = makeWindow()
        c.handle(.toggleBottomDrawer)
        c.window.contentView?.layoutSubtreeIfNeeded()
        let drawer = try XCTUnwrap(hosts(c).first { !paneHosts(c).contains($0) })
        let surface = try XCTUnwrap(surface(of: drawer))

        surface.currentDirectory = root
        surface.delegate?.surface(surface, cwdDidChange: root)

        XCTAssertEqual(
            drawer.header?.pathForTesting, PathDisplay.abbreviatingHome(root.path), "without waiting for a poll")
    }

    func test_aDrawersFocusModeButton_zoomsTheDrawer_andStaysLit() throws {
        let c = makeWindow()
        c.handle(.toggleBottomDrawer)
        c.window.contentView?.layoutSubtreeIfNeeded()
        let drawer = try XCTUnwrap(hosts(c).first { !paneHosts(c).contains($0) })

        try click(.focusMode, on: drawer.header, in: c.window)

        XCTAssertTrue(drawer.isZoomed)
        XCTAssertEqual(drawer.header?.buttonForTesting(.focusMode)?.isActive, true)
    }

    private func floatCard(_ c: WindowController) throws -> SurfaceFloatOverlay {
        try XCTUnwrap(descendants(of: c.window.contentView!).compactMap { $0 as? SurfaceFloatOverlay }.first)
    }

    func test_aKeptFloatsMinimize_hidesIt_andKeepsItsProgram() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        let card = try floatCard(c)
        let surface = try XCTUnwrap(spawned.last)
        XCTAssertEqual(card.header?.controlsForTesting, [.minimize, .end])

        try click(.minimize, on: card.header, in: c.window)

        XCTAssertFalse(c.floatsForTesting.isOpen)
        XCTAssertFalse(surface.terminated, "minimize hides; the program keeps running")
    }

    func test_scratchShowsItsFolder_theMomentItsShellReportsOne() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        let header = try floatCard(c).shownHeaderForTesting
        let surface = try XCTUnwrap(spawned.last)
        XCTAssertNil(header?.pathForTesting, "premise: the shell has not reported a folder yet")

        surface.currentDirectory = root
        surface.delegate?.surface(surface, cwdDidChange: root)

        XCTAssertEqual(header?.nameForTesting, "Scratch")
        XCTAssertEqual(header?.pathForTesting, PathDisplay.abbreviatingHome(root.path), "without waiting for a poll")
    }

    func test_aKeptFloatsClose_endsItsProgram() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        let card = try floatCard(c)
        let surface = try XCTUnwrap(spawned.last)

        try click(.end, on: card.header, in: c.window)

        XCTAssertFalse(c.floatsForTesting.isOpen)
        XCTAssertTrue(surface.terminated)
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        XCTAssertFalse(try XCTUnwrap(spawned.last) === surface, "reopening starts a fresh program")
    }

    func test_aBusyFloatsClose_asksFirst() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
        let card = try floatCard(c)
        let surface = try XCTUnwrap(spawned.last)
        surface.isBusy = true

        try click(.end, on: card.header, in: c.window)

        XCTAssertFalse(surface.terminated, "a busy float waits for the confirmation")
        XCTAssertNotNil(descendants(of: c.window.contentView!).first { $0 is ConfirmCard })
    }

    func test_aFloatThatEndsOnDismiss_offersOnlyClose() throws {
        let ephemeral = ToolFloat(
            id: "probe", order: 1, title: "Probe", icon: "hammer", command: "true", dir: nil,
            widthFraction: 0.6, heightFraction: 0.6, requiresGitRepo: false, persist: .ephemeral,
            toggle: Chord(command: true, control: true, key: "p"))
        var config = GeneralConfig.builtIn
        config.floats = [ephemeral]
        GeneralConfig.setCurrentForTesting(config)
        let c = makeWindow()

        c.handle(.toggleToolFloat(ephemeral.id))

        let header = try floatCard(c).shownHeaderForTesting
        XCTAssertEqual(header?.controlsForTesting, [.end], "minimize would end it too, so it is not offered")
        XCTAssertEqual(header?.nameForTesting, "Probe", "a tool float is named by its float")
        XCTAssertNil(header?.pathForTesting, "and its folder is not worth showing")
    }

    private func openProbeFloat(command: String = "true", icon: String = "hammer") throws
        -> (WindowController, ToolFloat, PaneHeader?, RecordingSurface)
    {
        let probe = ToolFloat(
            id: "probe", order: 1, title: "Probe", icon: icon, command: command, dir: nil,
            widthFraction: 0.6, heightFraction: 0.6, requiresGitRepo: false, persist: .window,
            toggle: Chord(command: true, control: true, key: "p"))
        var config = GeneralConfig.builtIn
        config.floats = [probe]
        GeneralConfig.setCurrentForTesting(config)
        let c = makeWindow()
        c.handle(.toggleToolFloat(probe.id))
        let header = try floatCard(c).shownHeaderForTesting
        return (c, probe, header, try XCTUnwrap(spawned.last))
    }

    func test_aToolFloatsHeader_leadsWithItsProgramsIcon() throws {
        let (c, _, header, surface) = try openProbeFloat()

        surface.foregroundProcessGroupID = try jobs.start(named: "lazygit")
        c.pollTitlesForTesting()

        XCTAssertEqual(header?.processForTesting.name, "Git")
        XCTAssertEqual(header?.nameForTesting, "Probe", "still named by its float")
    }

    func test_aToolFloatsHeader_keepsItsOwnIcon_forAProgramWithNone() throws {
        let (c, probe, header, surface) = try openProbeFloat()
        let tinted = try XCTUnwrap(ProcessIcon.toolFloat(probe))
        XCTAssertEqual(header?.processForTesting, tinted, "before its program starts")

        surface.foregroundProcessGroupID = try jobs.start(named: "zt-unlisted-tool")
        c.pollTitlesForTesting()

        XCTAssertEqual(header?.processForTesting, tinted)
    }

    func test_aToolFloatsHeader_showsAnAgentUnderARuntime_asTheAgent() throws {
        let (c, _, header, surface) = try openProbeFloat(command: "codex")

        surface.foregroundProcessGroupID = try jobs.start(named: "node")
        c.pollTitlesForTesting()

        XCTAssertEqual(header?.processForTesting, ProcessIcon.forAgent("codex"), "not Node.js, the way a pane reads it")
    }

    func test_aToolFloatsHeader_leadsWithItsCommandsIcon_whileTheLaunchShellIsInFront() throws {
        let (c, _, header, surface) = try openProbeFloat(command: "lazygit --path .")
        XCTAssertEqual(header?.processForTesting.name, "Git", "before the poll sees anything")

        surface.foregroundProcessGroupID = try jobs.start(named: "zsh")
        c.pollTitlesForTesting()

        XCTAssertEqual(header?.processForTesting.name, "Git", "not the float's own icon, then Git")
    }

    func test_aToolFloatsHeader_wearsAPickedBrandMark_inItsBrandsChip() throws {
        let (_, _, header, _) = try openProbeFloat(icon: "linear")

        XCTAssertEqual(header?.processForTesting.look, ProcessIcon.forProgram("linear").look)
        XCTAssertEqual(header?.processForTesting.name, "Probe")
    }

    func test_aToolFloatsHeader_returnsToItsOwnIcon_onceItsCommandLeavesAPrompt() throws {
        let (c, probe, header, surface) = try openProbeFloat(command: "lazygit")

        surface.foregroundProcessGroupID = try jobs.startWithoutArguments(named: "zsh")
        c.pollTitlesForTesting()

        XCTAssertEqual(header?.processForTesting, ProcessIcon.toolFloat(probe), "not Git after lazygit quits")
    }
}
