import AppKit
import XCTest

@testable import ZenTerm

final class NewWorktreeOverlayTests: WindowTestCase {
    private final class Sink {
        var submitted: [NewWorktreeOverlay.Request] = []
        var cancelled = 0
        var dismissed = 0
        var editedWorkspace = 0
    }

    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        Motion.isReduceMotionEnabled = { true }
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    func test_submittingAnEmptyBranch_flagsTheFieldAndDoesNotSubmit() throws {
        let (overlay, sink) = mount()

        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(inlineMessage(in: overlay), "Enter a branch name.")
    }

    func test_anExistingBranch_isTakenRatherThanRefused() throws {
        let (overlay, sink) = mount(branches: ["feature/zen-473"])

        type("feature/zen-473", into: overlay)
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(sink.submitted.first, .existingBranch("feature/zen-473"))
        XCTAssertNil(inlineMessage(in: overlay))
    }

    func test_anExistingBranch_hidesTheBaseGroupAndBringsItBack() throws {
        let (overlay, _) = mount(branches: ["feature/zen-473"])

        type("feature/zen-473", into: overlay)
        XCTAssertTrue(try XCTUnwrap(segment(in: overlay)).isHiddenOrHasHiddenAncestor)

        type("feature/zen-999", into: overlay)
        XCTAssertFalse(try XCTUnwrap(segment(in: overlay)).isHiddenOrHasHiddenAncestor)
    }

    func test_anExistingBranch_saysSoBeforeCreateIsPressed() throws {
        let (overlay, _) = mount(branches: ["feature/zen-473"])

        type("feature/zen-473", into: overlay)

        XCTAssertTrue(
            visibleText(in: overlay).contains("Uses the existing branch feature/zen-473."))
    }

    func test_aBranchAWorktreeAlreadyHas_blocksSubmit() throws {
        let (overlay, sink) = mount(
            branches: ["feature/zen-473"],
            holders: ["feature/zen-473": .worktree(URL(fileURLWithPath: "/tmp/wt"))])

        type("feature/zen-473", into: overlay)
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(inlineMessage(in: overlay), "feature/zen-473 already has a worktree.")
    }

    func test_withTheBaseHidden_downFromTheBranchFieldReachesTheCopyButton() throws {
        let (overlay, _) = mount(branches: ["feature/zen-473"])
        let copyButton = try XCTUnwrap(button(in: overlay, title: "Choose what to copy"))
        type("feature/zen-473", into: overlay)
        let box = branchField(in: overlay)
        window?.makeFirstResponder(box.field)

        _ = box.control(
            box.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))

        XCTAssertTrue(KeyboardFocus.isFocused(copyButton, in: window))
    }

    func test_theRefFileConflictChecks_areSilentForABranchThatExists() throws {
        let (overlay, sink) = mount(branches: ["feature", "feature/zen-473"])

        type("feature", into: overlay)
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(sink.submitted.first, .existingBranch("feature"))
        XCTAssertNil(inlineMessage(in: overlay))
    }

    func test_aBranchTheMainCheckoutHolds_asksBeforeMovingIt() throws {
        let (overlay, sink) = mount(
            branches: ["feature/zen-473"],
            holders: ["feature/zen-473": .mainCheckout(URL(fileURLWithPath: "/tmp/repo"))])

        type("feature/zen-473", into: overlay)
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty, "nothing is created until the question is answered")
        XCTAssertTrue(visibleText(in: overlay).contains("Move Your Main Checkout"))
    }

    func test_theDefaultBranchUnderTheMainCheckout_isRefusedRatherThanConfirmed() throws {
        let (overlay, sink) = mount(
            branches: ["main"], defaultBase: "origin/main",
            holders: ["main": .mainCheckout(URL(fileURLWithPath: "/tmp/repo"))])

        type("main", into: overlay)
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(
            inlineMessage(in: overlay),
            "main is the default branch, so your main checkout cannot move off it.")
        XCTAssertFalse(
            visibleText(in: overlay).contains("Move Your Main Checkout"), "no confirm was shown")
    }

    func test_submitting_takesTheSuggestionListDown() throws {
        let (overlay, _) = mount(branches: ["main", "main-ish"])
        type("main", into: overlay)
        XCTAssertTrue(branchListIsOpen(in: overlay))

        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertFalse(branchListIsOpen(in: overlay))
    }

    func test_withTheConfirmUp_theCardReportsAnOverlaidCard() throws {
        let (overlay, _) = mount(
            branches: ["feature/zen-473"],
            holders: ["feature/zen-473": .mainCheckout(URL(fileURLWithPath: "/tmp/repo"))])
        XCTAssertFalse(overlay.isShowingOverlaidCard)

        type("feature/zen-473", into: overlay)
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(overlay.isShowingOverlaidCard)
    }

    func test_confirmingTheMove_submitsTheExistingBranch() throws {
        let (overlay, sink) = mount(
            branches: ["feature/zen-473"],
            holders: ["feature/zen-473": .mainCheckout(URL(fileURLWithPath: "/tmp/repo"))])
        type("feature/zen-473", into: overlay)
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        try XCTUnwrap(button(in: confirmCard(in: overlay), title: "Create Worktree")).onTap()

        XCTAssertEqual(sink.submitted.first, .existingBranch("feature/zen-473"))
    }

    func test_cancellingTheMove_createsNothing() throws {
        let (overlay, sink) = mount(
            branches: ["feature/zen-473"],
            holders: ["feature/zen-473": .mainCheckout(URL(fileURLWithPath: "/tmp/repo"))])
        type("feature/zen-473", into: overlay)
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        try XCTUnwrap(button(in: confirmCard(in: overlay), title: "Cancel")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
    }

    func test_escapeWithTheConfirmUp_leavesTheCardStanding() throws {
        let (overlay, sink) = mount(
            branches: ["feature/zen-473"],
            holders: ["feature/zen-473": .mainCheckout(URL(fileURLWithPath: "/tmp/repo"))])
        type("feature/zen-473", into: overlay)
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        pressEscape()

        XCTAssertEqual(sink.cancelled, 0, "the confirm answered its own Esc")
        XCTAssertTrue(sink.submitted.isEmpty)
    }

    func test_theMoveMessage_namesTheLocalBranchTheCheckoutLandsOn() {
        XCTAssertEqual(
            NewWorktreeOverlay.moveMainCheckoutMessage("feature/x", to: "origin/main"),
            """
            feature/x is checked out in your main checkout. Creating this worktree moves that \
            checkout to main, so any shell open there will be on main.
            """)
    }

    func test_aLeadingDash_neverReachesGit() throws {
        let (overlay, sink) = mount()

        branchField(in: overlay).setText("-m")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(inlineMessage(in: overlay), "Can't start with a dash.")
    }

    func test_aBranchWithASpace_isRefused() throws {
        let (overlay, sink) = mount()

        branchField(in: overlay).setText("my branch")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(inlineMessage(in: overlay), "Can't contain spaces.")
    }

    func test_aNameAlreadyUsedAsAFolder_isRefused() throws {
        let (overlay, sink) = mount(branches: ["test/branch-test", "test/test-1"])

        branchField(in: overlay).setText("test")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(
            inlineMessage(in: overlay), "test/branch-test already uses this name as a folder.",
            "names the offender, and the same one every run")
    }

    func test_aNameUnderAnExistingBranch_isRefused() throws {
        let (overlay, sink) = mount(branches: ["test"])

        branchField(in: overlay).setText("test/spike")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(
            inlineMessage(in: overlay), "test is already a branch, so this can't be a folder.")
    }

    func test_aDeepNameUnderAnExistingBranch_namesTheBranchInTheWay() throws {
        let (overlay, _) = mount(branches: ["feature/zen"])

        branchField(in: overlay).setText("feature/zen/473")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(
            inlineMessage(in: overlay), "feature/zen is already a branch, so this can't be a folder.")
    }

    func test_aNameSharingAPrefixButNotASegment_isFine() throws {
        let (overlay, sink) = mount(branches: ["test/branch-test"])

        branchField(in: overlay).setText("testing")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(sink.submitted.first, .newBranch("testing", .defaultBranch))
    }

    func test_submit_handsBackTheTrimmedBranchAndTheDefaultBase() throws {
        let (overlay, sink) = mount()

        branchField(in: overlay).setText("  feature/zen-473  ")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(sink.submitted.first, .newBranch("feature/zen-473", .defaultBranch))
    }

    func test_theSecondBaseSegment_cutsFromTheCurrentCheckout() throws {
        let (overlay, sink) = mount()

        try XCTUnwrap(segment(in: overlay)).select(1)
        branchField(in: overlay).setText("spike")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(sink.submitted.first, .newBranch("spike", .currentCheckout))
    }

    func test_whileWorking_bothButtonsAreOffAndEscapeDoesNothing() throws {
        let (overlay, sink) = mount()

        overlay.beginWork("Creating spike")

        XCTAssertFalse(try XCTUnwrap(button(in: overlay, title: "Create Worktree")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(button(in: overlay, title: "Cancel")).isEnabled)
        pressEscape()
        XCTAssertEqual(sink.cancelled, 0)
    }

    func test_whileWorking_aSecondSubmitDoesNotRunTheCreateTwice() throws {
        let (overlay, sink) = mount()

        branchField(in: overlay).setText("spike")
        let create = try XCTUnwrap(button(in: overlay, title: "Create Worktree"))
        create.onTap()
        overlay.beginWork("Creating spike")
        create.onTap()

        XCTAssertEqual(sink.submitted.count, 1)
    }

    func test_failing_handsTheCardBackWithTheReason() throws {
        let (overlay, sink) = mount()
        overlay.beginWork("Creating spike")

        overlay.failWork("A branch named spike already exists.")

        XCTAssertTrue(try XCTUnwrap(button(in: overlay, title: "Create Worktree")).isEnabled)
        XCTAssertEqual(
            visibleText(in: overlay).first { $0.hasPrefix("A branch named") },
            "A branch named spike already exists.")
        pressEscape()
        XCTAssertEqual(sink.cancelled, 1)
    }

    func test_theBaseCaption_namesTheRefEachChoiceCutsFrom() throws {
        let (overlay, _) = mount(defaultBase: "origin/main", currentBranch: "feature/zen-455")

        XCTAssertTrue(visibleText(in: overlay).contains("Starts from origin/main."))
        try XCTUnwrap(segment(in: overlay)).select(1)
        XCTAssertTrue(visibleText(in: overlay).contains("Starts from feature/zen-455."))
    }

    func test_withNothingToName_theCaptionStillSaysWhichChoiceItIs() throws {
        let (overlay, _) = mount(defaultBase: nil, currentBranch: nil)

        XCTAssertTrue(visibleText(in: overlay).contains("Starts from the default branch."))
        try XCTUnwrap(segment(in: overlay)).select(1)
        XCTAssertTrue(visibleText(in: overlay).contains("Starts from this checkout."))
    }

    func test_thePhaseLine_isHiddenAtRestAndNamesTheStepWhileWorking() {
        let (overlay, _) = mount()

        XCTAssertFalse(visibleText(in: overlay).contains("Creating spike"))
        overlay.beginWork("Creating spike")
        XCTAssertTrue(visibleText(in: overlay).contains("Creating spike"))

        overlay.setPhase("Carrying node_modules")
        XCTAssertTrue(visibleText(in: overlay).contains("Carrying node_modules"))
        XCTAssertFalse(visibleText(in: overlay).contains("Creating spike"))
    }

    func test_failing_takesThePhaseLineBackDown() {
        let (overlay, _) = mount()
        overlay.beginWork("Creating spike")

        overlay.failWork("That branch already exists.")

        XCTAssertFalse(visibleText(in: overlay).contains("Creating spike"))
    }

    func test_theBackdrop_dismissesRatherThanReturningToThePicker() throws {
        let (overlay, sink) = mount()

        try XCTUnwrap(backdrop(in: overlay)).mouseDown(with: NSEvent())

        XCTAssertEqual(sink.dismissed, 1)
        XCTAssertEqual(sink.cancelled, 0)
    }

    func test_theCancelButton_returnsToThePickerRatherThanDismissing() throws {
        let (overlay, sink) = mount()

        try XCTUnwrap(button(in: overlay, title: "Cancel")).onTap()

        XCTAssertEqual(sink.cancelled, 1)
        XCTAssertEqual(sink.dismissed, 0)
    }

    func test_whileWorking_theBackdropIsDeadToo() throws {
        let (overlay, sink) = mount()
        overlay.beginWork("Creating spike")

        try XCTUnwrap(backdrop(in: overlay)).mouseDown(with: NSEvent())

        XCTAssertEqual(sink.dismissed, 0)
    }

    func test_whileWorking_theBaseSegmentIsLocked() throws {
        let (overlay, _) = mount()
        let base = try XCTUnwrap(segment(in: overlay))

        overlay.beginWork("Creating spike")

        XCTAssertEqual(segmentButtons(in: base).filter(\.isEnabled), [])
        XCTAssertFalse(base.acceptsFirstResponder)
        XCTAssertTrue(visibleText(in: overlay).contains("Starts from origin/main."))

        overlay.failWork("nope")

        XCTAssertEqual(segmentButtons(in: base).filter { !$0.isEnabled }, [], "and it comes back")
        XCTAssertTrue(base.acceptsFirstResponder)
    }

    func test_typingAfterAFailure_clearsTheError() throws {
        let (overlay, _) = mount()
        overlay.beginWork("Creating spike")
        overlay.failWork("That branch already exists.")

        branchField(in: overlay).setText("spike-2")
        branchField(in: overlay).onChange?()

        XCTAssertFalse(visibleText(in: overlay).contains("That branch already exists."))
    }

    func test_theCopyLine_namesWhatComesAcross() throws {
        let (overlay, _) = mount(carry: ["node_modules", ".env"])

        XCTAssertTrue(visibleText(in: overlay).contains("node_modules, .env"))
    }

    func test_withNoCarryConfigured_thereIsOnlyTheButton() throws {
        let (overlay, _) = mount(carry: [])

        XCTAssertNotNil(button(in: overlay, title: "Choose what to copy"))
        XCTAssertFalse(visibleText(in: overlay).contains("Nothing set"))
    }

    func test_theCopyButton_opensTheWorkspaceForm() throws {
        let (overlay, sink) = mount(carry: [])
        let copyButton = try XCTUnwrap(button(in: overlay, title: "Choose what to copy"))

        copyButton.onTap()

        XCTAssertEqual(sink.editedWorkspace, 1)
    }

    func test_withCarryAlreadySet_theButtonOffersToChangeIt() throws {
        let (overlay, _) = mount(carry: ["node_modules"])

        XCTAssertNotNil(button(in: overlay, title: "Change what to copy"))
        XCTAssertNil(button(in: overlay, title: "Choose what to copy"))
    }

    func test_withNoWayToEditTheWorkspace_thereIsNoButton() throws {
        let (overlay, _) = mount(carry: [], canEditWorkspace: false)

        XCTAssertTrue(try XCTUnwrap(button(in: overlay, title: "Choose what to copy")).isHidden)
    }

    func test_theCopyButton_isAKeyboardStopBetweenBaseAndCreate() throws {
        let (overlay, _) = mount(carry: [])
        let base = try XCTUnwrap(segment(in: overlay))
        let copyButton = try XCTUnwrap(button(in: overlay, title: "Choose what to copy"))
        window?.makeFirstResponder(base)

        base.keyDown(with: try arrow(down: true))

        XCTAssertTrue(KeyboardFocus.isFocused(copyButton, in: window))
    }

    func test_aCreateInFlight_locksTheCopyButton() throws {
        let (overlay, sink) = mount(carry: [])
        let copyButton = try XCTUnwrap(button(in: overlay, title: "Choose what to copy"))

        overlay.beginWork("Creating spike")
        copyButton.onTap()

        XCTAssertFalse(copyButton.isEnabled)
        XCTAssertEqual(sink.editedWorkspace, 0)
    }

    func test_downAndUp_walkTheBaseSegmentBetweenTheBranchFieldAndCopy() throws {
        let (overlay, _) = mount()
        let base = try XCTUnwrap(segment(in: overlay))
        let copyButton = try XCTUnwrap(button(in: overlay, title: "Choose what to copy"))
        window?.makeFirstResponder(base)

        base.keyDown(with: try arrow(down: true))
        XCTAssertTrue(KeyboardFocus.isFocused(copyButton, in: window))

        copyButton.keyDown(with: try arrow(down: false))
        XCTAssertTrue(KeyboardFocus.isFocused(base, in: window))
    }

    func test_upFromCancel_reachesTheCopyButton() throws {
        let (overlay, _) = mount()
        let copyButton = try XCTUnwrap(button(in: overlay, title: "Choose what to copy"))
        let cancel = try XCTUnwrap(button(in: overlay, title: "Cancel"))
        window?.makeFirstResponder(cancel)

        cancel.keyDown(with: try arrow(down: false))

        XCTAssertTrue(KeyboardFocus.isFocused(copyButton, in: window))
    }

    private func mount(
        carry: [String] = [], branches: Set<String> = [], defaultBase: String? = "origin/main",
        currentBranch: String? = "feature/zen-455", canEditWorkspace: Bool = true,
        holders: [String: WorktreeStore.Holder] = [:]
    ) -> (overlay: NewWorktreeOverlay, sink: Sink) {
        let sink = Sink()
        let workspace = Workspace(
            title: "ZenTerm", path: URL(fileURLWithPath: "/tmp/zenterm-fixture"),
            main: nil, right: nil, bottom: nil, focus: .main, env: [:], carry: carry)
        let overlay = NewWorktreeOverlay(
            workspace: workspace,
            options: WorktreeStore.CreateOptions(
                branches: branches, defaultBase: defaultBase, currentBranch: currentBranch,
                holders: holders),
            background: Theme.current.chrome.background.nsColor,
            onSubmit: { sink.submitted.append($0) },
            onCancel: { sink.cancelled += 1 },
            onDismiss: { sink.dismissed += 1 },
            onEditWorkspace: canEditWorkspace ? { sink.editedWorkspace += 1 } : nil)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        win.contentView?.layoutSubtreeIfNeeded()
        window = win
        return (overlay, sink)
    }

    private func type(_ text: String, into overlay: NSView) {
        let box = branchField(in: overlay)
        box.setText(text)
        box.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: box.field))
    }

    private func branchListIsOpen(in overlay: NSView) -> Bool {
        descendants(of: overlay).compactMap { $0 as? BranchField }.first?.isListOpen ?? false
    }

    private func confirmCard(in overlay: NSView) -> NSView {
        descendants(of: overlay).compactMap { $0 as? ConfirmCard }.first!
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func branchField(in overlay: NSView) -> FieldBox {
        descendants(of: overlay).compactMap { $0 as? FieldBox }.first!
    }

    private func button(in overlay: NSView, title: String) -> AppButton? {
        descendants(of: overlay).compactMap { $0 as? AppButton }.first { $0.title == title }
    }

    private func segmentButtons(in segment: SegmentedControl) -> [AppButton] {
        descendants(of: segment).compactMap { $0 as? AppButton }
    }

    private func backdrop(in overlay: NSView) -> BackdropView? {
        descendants(of: overlay).compactMap { $0 as? BackdropView }.first
    }

    private func segment(in overlay: NSView) -> SegmentedControl? {
        descendants(of: overlay).compactMap { $0 as? SegmentedControl }.first
    }

    private func visibleText(in overlay: NSView) -> [String] {
        descendants(of: overlay)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
            .map(\.stringValue)
    }

    private func inlineMessage(in overlay: NSView) -> String? {
        guard let group = descendants(of: overlay).compactMap({ $0 as? LabeledField }).first
        else { return nil }
        return descendants(of: group)
            .compactMap { $0 as? NSTextField }
            .first { !($0 is FieldCaption) && !$0.isEditable && !$0.isHidden }?
            .stringValue
    }

    private func arrow(down: Bool) throws -> NSEvent {
        let character = String(UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!)
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                timestamp: 0, windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false,
                keyCode: down ? 125 : 126))
    }

    @discardableResult
    private func pressEscape() -> Bool {
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        return window!.contentView!.performKeyEquivalent(with: esc)
    }
}
