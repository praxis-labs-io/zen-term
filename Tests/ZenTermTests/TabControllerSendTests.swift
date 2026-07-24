import AppKit
import PaneKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The tab side of a diff comment (ZEN-257): which terminals it offers, and what actually reaches the
/// surface. The paste shape is the load-bearing part — `TerminalSurface.paste` is bracketed, so the
/// message has to arrive as one paste and the Return as a separate one, or a TUI reads the Return as
/// a literal newline inside the block and the message sits there unsent.
final class TabControllerSendTests: XCTestCase {
    private var window: NSWindow?
    private var controller: TabController?
    private var surfaces: [RecordingSurface] = []

    override func setUp() {
        super.setUp()
        surfaces = []
    }

    override func tearDown() {
        controller?.shutdown()
        controller = nil
        window = nil
        super.tearDown()
    }

    @discardableResult
    private func mount() -> TabController {
        let controller = TabController(
            initialCWD: nil,
            makeSurface: { [weak self] in
                let surface = RecordingSurface()
                self?.surfaces.append(surface)
                return surface
            })
        self.controller = controller
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        win.contentView?.addSubview(controller.view)
        controller.view.layoutSubtreeIfNeeded()
        window = win
        controller.start()  // the initial pane's surface is spawned here, not in init
        return controller
    }

    // MARK: the target list

    func test_asinglePaneTabOffersThatPane() {
        let controller = mount()
        let targets = controller.sendTargets()
        XCTAssertEqual(targets.count, 1)
        XCTAssertTrue(
            targets[0].label.hasPrefix("pane 1"),
            "the place leads the label, so an untitled shell is still nameable: \(targets[0].label)")
    }

    func test_aSurfaceTitleNamesWhatsRunningThere() {
        let controller = mount()
        surfaces.first?.title = "claude"
        XCTAssertEqual(controller.sendTargets().first?.label, "pane 1 · claude")
    }

    func test_aClosedDrawerIsNotOffered() {
        let controller = mount()
        XCTAssertEqual(
            controller.sendTargets().count, 1,
            "pasting into a hidden drawer would put text where you can't see it")
    }

    func test_anOpenDrawerJoinsTheList_andTheFocusedOneLeadsIt() {
        let controller = mount()
        controller.toggleBottomDrawer()

        let targets = controller.sendTargets()
        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(
            targets[0].label, "bottom drawer",
            "opening the drawer focused it, and the composer defaults to index 0 — so a comment "
                + "lands where you were working")
        XCTAssertTrue(targets[1].label.hasPrefix("pane 1"))
    }

    // MARK: sending

    func test_theMessageArrivesAsOnePaste() throws {
        let controller = mount()
        let target = try XCTUnwrap(controller.sendTargets().first)
        let pane = try XCTUnwrap(surfaces.first)

        controller.send("Foo.swift:42 look at this", to: target, submit: false)

        XCTAssertEqual(
            pane.pastes, ["Foo.swift:42 look at this"],
            "one paste: bracketed, so even a multi-line message reaches the input as a block")
    }

    func test_submitSendsARealReturnKeyNotAPastedCarriageReturn() throws {
        let controller = mount()
        let target = try XCTUnwrap(controller.sendTargets().first)
        let pane = try XCTUnwrap(surfaces.first)

        controller.send("Foo.swift:42 ship it", to: target, submit: true)

        XCTAssertEqual(
            pane.pastes, ["Foo.swift:42 ship it"],
            "only the message is pasted — the Return is a keypress, not a bracketed \"\\r\" the TUI "
                + "would read as a newline")
        XCTAssertEqual(pane.submitCount, 1, "and the submit went through the real key path")
    }

    func test_noSubmitSendsNoReturnKey() throws {
        let controller = mount()
        let target = try XCTUnwrap(controller.sendTargets().first)
        let pane = try XCTUnwrap(surfaces.first)

        controller.send("Foo.swift:42 look", to: target, submit: false)

        XCTAssertEqual(pane.pastes, ["Foo.swift:42 look"])
        XCTAssertEqual(pane.submitCount, 0, "⏎ leaves the message in the input, unsent")
    }

    func test_sendingFocusesTheTargetSoYouLandWhereTheTextWent() throws {
        let controller = mount()
        controller.toggleBottomDrawer()
        // The pane, not the drawer that just took focus — the case where focus has to move.
        let pane = try XCTUnwrap(controller.sendTargets().first { $0.label.hasPrefix("pane 1") })
        let paneSurface = try XCTUnwrap(surfaces.first)

        controller.send("Foo.swift:1 over here", to: pane, submit: false)

        XCTAssertEqual(paneSurface.pastes, ["Foo.swift:1 over here"])
        XCTAssertTrue(paneSurface.isFocused, "focus follows the message")
    }

    func test_aSendToADeadTargetIsANoOp() throws {
        let controller = mount()
        let ghost = DiffSendTarget(id: PaneID(9999), label: "gone")

        controller.send("Foo.swift:1 anyone?", to: ghost, submit: true)

        XCTAssertTrue(
            surfaces.allSatisfy { $0.pastes.isEmpty },
            "a stale target writes nowhere rather than into whatever pane happens to be focused")
    }
}
