import XCTest

@testable import ZenTerm

final class WorkspaceFormTests: XCTestCase {
    private func editing(_ tabs: [Workspace.Tab], focus: Workspace.LaunchFocus = .start) -> WorkspaceForm {
        WorkspaceForm(
            editing: Workspace(
                title: "W", path: URL(fileURLWithPath: "/tmp"), tabs: tabs, focus: focus, env: [:]))
    }

    func test_aNewForm_holdsOneShellTabFocusedOnItsMainPane_andNamesItselfFromTheFolder() {
        let form = WorkspaceForm(editing: nil)

        XCTAssertEqual(form.tabs, [Workspace.Tab()])
        XCTAssertEqual(form.launchFocus, .start)
        XCTAssertEqual(form.chipLabel(at: 0), "shell")
        XCTAssertTrue(form.isSoleTab)
        XCTAssertTrue(form.nameFollowsFolder)
    }

    func test_anEditedWorkspace_keepsItsName() {
        XCTAssertFalse(editing([Workspace.Tab()]).nameFollowsFolder)
    }

    func test_aChip_readsItsName_thenItsMainCommand_thenShell() {
        let form = editing([
            Workspace.Tab(name: "gate", main: "bin/check"), Workspace.Tab(main: "nvim"), Workspace.Tab(right: "claude"),
        ])

        XCTAssertEqual((0..<3).map(form.chipLabel(at:)), ["gate", "nvim", "shell"])
    }

    func test_addingATab_appendsAnEmptyOne_andSelectsIt() {
        var form = editing([Workspace.Tab(main: "nvim")])

        form.addTab()

        XCTAssertEqual(form.tabs, [Workspace.Tab(main: "nvim"), Workspace.Tab()])
        XCTAssertEqual(form.selected, 1)
        XCTAssertEqual(form.launchFocus, .start, "the dot stays on the tab that opens focused")
    }

    func test_renaming_trimsTheName_andAnEmptyNameGoesBackToUnnamed() {
        var form = editing([Workspace.Tab(name: "old", main: "nvim")])

        form.renameTab(at: 0, to: "  code ")
        XCTAssertEqual(form.tabs[0].name, "code")

        form.renameTab(at: 0, to: "   ")
        XCTAssertNil(form.tabs[0].name)
        XCTAssertEqual(form.chipLabel(at: 0), "nvim")
    }

    func test_theSoleTab_cannotBeRemoved() {
        var form = editing([Workspace.Tab(main: "nvim")])

        XCTAssertNil(form.removeTab(at: 0))
        XCTAssertEqual(form.tabs.count, 1)
        XCTAssertNil(form.lastRemoval)
    }

    func test_removingTheTabThatOpensFocused_movesFocusToTheFirstRemainingMainPane_andSaysSo() {
        var form = editing(
            [Workspace.Tab(main: "nvim", right: "claude"), Workspace.Tab(name: "gate", bottom: "bin/check")],
            focus: Workspace.LaunchFocus(tab: 0, region: .right))

        let notice = form.removeTab(at: 0)

        XCTAssertEqual(notice, "Removed nvim. gate's main pane opens focused.")
        XCTAssertEqual(form.launchFocus, .start)
        XCTAssertEqual(form.tabs, [Workspace.Tab(name: "gate", bottom: "bin/check")])
        XCTAssertEqual(form.selected, 0)
    }

    func test_removingAnotherTab_keepsFocusOnTheSameTab_atItsNewIndex() {
        var form = editing(
            [Workspace.Tab(main: "a"), Workspace.Tab(main: "b"), Workspace.Tab(main: "c", right: "r")],
            focus: Workspace.LaunchFocus(tab: 2, region: .right))
        form.select(2)

        XCTAssertEqual(form.removeTab(at: 0), "Removed a.")

        XCTAssertEqual(form.launchFocus, Workspace.LaunchFocus(tab: 1, region: .right))
        XCTAssertEqual(form.selected, 1, "the selection stays on c")
    }

    func test_removingTheLastSelectedTab_selectsTheOneBeforeIt() {
        var form = editing([Workspace.Tab(main: "a"), Workspace.Tab(main: "b")])
        form.select(1)

        _ = form.removeTab(at: 1)

        XCTAssertEqual(form.selected, 0)
    }

    func test_movingTheLaunchFocus_afterARemoval_takesUndoAway() {
        var form = editing([Workspace.Tab(main: "nvim", right: "claude"), Workspace.Tab(name: "gate")])

        _ = form.removeTab(at: 1)
        form.setLaunchFocus(.right, inTab: 0)

        XCTAssertNil(form.lastRemoval, "undo would put back the focus the user just moved")
    }

    func test_undo_putsTheTabFocusAndSelectionBack() {
        let tabs = [Workspace.Tab(main: "nvim", right: "claude"), Workspace.Tab(name: "gate")]
        let focus = Workspace.LaunchFocus(tab: 0, region: .right)
        var form = editing(tabs, focus: focus)

        _ = form.removeTab(at: 0)
        form.undoRemoval()

        XCTAssertEqual(form.tabs, tabs)
        XCTAssertEqual(form.launchFocus, focus)
        XCTAssertEqual(form.selected, 0)
        XCTAssertNil(form.lastRemoval)
    }

    func test_theNextTabChange_endsTheUndo() {
        var form = editing([Workspace.Tab(main: "a"), Workspace.Tab(main: "b"), Workspace.Tab(main: "c")])

        _ = form.removeTab(at: 0)
        form.addTab()
        XCTAssertNil(form.lastRemoval, "adding")

        _ = form.removeTab(at: 0)
        form.moveTab(at: 0, to: 1)
        XCTAssertNil(form.lastRemoval, "moving")

        _ = form.removeTab(at: 0)
        form.renameTab(at: 0, to: "x")
        XCTAssertNil(form.lastRemoval, "renaming")
    }

    func test_moving_carriesTheLaunchFocusAndSelectionWithTheirTabs() {
        var form = editing(
            [Workspace.Tab(main: "a"), Workspace.Tab(main: "b"), Workspace.Tab(main: "c")],
            focus: Workspace.LaunchFocus(tab: 0, region: .main))
        form.select(2)

        form.moveTab(at: 0, to: 2)

        XCTAssertEqual(form.tabs.map(\.main), ["b", "c", "a"])
        XCTAssertEqual(form.launchFocus.tab, 2, "focus follows a")
        XCTAssertEqual(form.selected, 1, "the selection follows c")

        form.moveTab(at: 2, to: 0)
        XCTAssertEqual(form.tabs.map(\.main), ["a", "b", "c"])
        XCTAssertEqual(form.launchFocus.tab, 0)
        XCTAssertEqual(form.selected, 2)
    }

    func test_movingPastAnEnd_clampsAndDoesNothingAtTheEdge() {
        var form = editing([Workspace.Tab(main: "a"), Workspace.Tab(main: "b")])

        form.moveTab(at: 0, to: -1)
        XCTAssertEqual(form.tabs.map(\.main), ["a", "b"])

        form.moveTab(at: 0, to: 5)
        XCTAssertEqual(form.tabs.map(\.main), ["b", "a"])
    }

    func test_aClosedDrawer_cannotOpenFocused() {
        var form = editing([Workspace.Tab(main: "nvim")])

        XCTAssertFalse(form.setLaunchFocus(.right, inTab: 0))
        XCTAssertEqual(form.launchFocus, .start)

        form.setCommand("claude", in: .right, ofTab: 0)
        XCTAssertTrue(form.setLaunchFocus(.right, inTab: 0))
        XCTAssertEqual(form.launchFocus, Workspace.LaunchFocus(tab: 0, region: .right))
    }

    func test_emptyingTheFocusedDrawer_movesFocusToItsTabsMainPane_andSaysSo() {
        var form = editing(
            [Workspace.Tab(main: "a"), Workspace.Tab(name: "gate", bottom: "bin/check")],
            focus: Workspace.LaunchFocus(tab: 1, region: .bottom))

        form.setCommand("  ", in: .bottom, ofTab: 1)

        XCTAssertNil(form.tabs[1].bottom)
        XCTAssertEqual(
            form.build().focus, Workspace.LaunchFocus(tab: 1, region: .main), "a save never names a closed drawer")
        XCTAssertEqual(form.repairLaunchFocus(), "The bottom drawer is closed. gate's main pane opens focused.")
        XCTAssertEqual(form.launchFocus, Workspace.LaunchFocus(tab: 1, region: .main))
        XCTAssertNil(form.repairLaunchFocus(), "nothing left to repair")
    }

    func test_aWorkspaceFocusedOnAClosedDrawer_opensFocusedOnThatTabsMainPane() {
        let form = editing(
            [Workspace.Tab(main: "a"), Workspace.Tab(main: "b")], focus: Workspace.LaunchFocus(tab: 1, region: .right))

        XCTAssertEqual(form.launchFocus, Workspace.LaunchFocus(tab: 1, region: .main))
    }

    func test_commands_areTrimmed_andEmptyMeansNone() {
        var form = WorkspaceForm(editing: nil)

        form.setCommand(" nvim ", in: .main, ofTab: 0)
        form.setCommand("shell", in: .bottom, ofTab: 0)
        form.setCommand("", in: .right, ofTab: 0)

        XCTAssertEqual(form.build().tabs, [Workspace.Tab(main: "nvim", bottom: "shell")])
    }

    func test_aFlatWorkspace_buildsBackToItself() {
        let tabs = [Workspace.Tab(main: "nvim", right: "claude", bottom: "shell")]
        let focus = Workspace.LaunchFocus(tab: 0, region: .right)

        let built = editing(tabs, focus: focus).build()

        XCTAssertEqual(built.tabs, tabs)
        XCTAssertEqual(built.focus, focus)
    }

    func test_theNameFollowsTheFolder_onlyWhileItIsEmptyOrFilledForYou() {
        var form = WorkspaceForm(editing: nil)

        form.nameEdited("site")
        XCTAssertFalse(form.nameFollowsFolder, "a typed name is never replaced")

        form.nameEdited("")
        XCTAssertTrue(form.nameFollowsFolder, "clearing it hands the name back to the folder")
    }

    func test_theFolderName_isItsLastPathPart() {
        XCTAssertEqual(WorkspaceForm.folderName("~/Dev/zen-term"), "zen-term")
        XCTAssertEqual(WorkspaceForm.folderName("/tmp/my-project/ "), "my-project")
        XCTAssertEqual(WorkspaceForm.folderName("  "), "")
        XCTAssertEqual(WorkspaceForm.folderName("/"), "")
    }
}
