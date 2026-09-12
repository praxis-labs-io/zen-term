import AppKit
import XCTest

@testable import ZenTerm

/// The create-a-worktree card, driven through its real controls in a window. A state-only test
/// would pass while a control was dead.
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

    // MARK: validation

    func test_submittingAnEmptyBranch_flagsTheFieldAndDoesNotSubmit() throws {
        let (overlay, sink) = mount()

        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(inlineMessage(in: overlay), "Enter a branch name.")
    }

    // MARK: an existing branch

    func test_anExistingBranch_isTakenRatherThanRefused() throws {
        let (overlay, sink) = mount(branches: ["feature/zen-473"])

        type("feature/zen-473", into: overlay)
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(sink.submitted.first, .existingBranch("feature/zen-473"))
        XCTAssertNil(inlineMessage(in: overlay))
    }

    /// There is no base to choose for a branch that is already at a commit.
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

    /// A hidden control is still a focus stop unless it is taken out of the list, and arrowing
    /// into one looks exactly like the arrow doing nothing.
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

    /// `a` and `a/b` cannot both be refs, but that is a rule about cutting a new branch. Reporting
    /// it against a branch the user just picked from the list would be nonsense.
    func test_theRefFileConflictChecks_areSilentForABranchThatExists() throws {
        let (overlay, sink) = mount(branches: ["feature", "feature/zen-473"])

        type("feature", into: overlay)
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(sink.submitted.first, .existingBranch("feature"))
        XCTAssertNil(inlineMessage(in: overlay))
    }

    // MARK: the main checkout's confirm

    func test_aBranchTheMainCheckoutHolds_asksBeforeMovingIt() throws {
        let (overlay, sink) = mount(
            branches: ["feature/zen-473"],
            holders: ["feature/zen-473": .mainCheckout(URL(fileURLWithPath: "/tmp/repo"))])

        type("feature/zen-473", into: overlay)
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty, "nothing is created until the question is answered")
        XCTAssertTrue(visibleText(in: overlay).contains("Move Your Main Checkout"))
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

    /// The message has to name where the checkout lands, and must never say "origin/main": that
    /// is a remote ref, and checking one out detaches HEAD.
    func test_theMoveMessage_namesTheLocalBranchTheCheckoutLandsOn() {
        XCTAssertEqual(
            NewWorktreeOverlay.moveMainCheckoutMessage("feature/x", to: "origin/main"),
            """
            feature/x is checked out in your main checkout. Creating this worktree moves that \
            checkout to main, so any shell open there will be on main.
            """)
    }

    /// `check-ref-format` passes `-m`, and `worktree add -b -m` then renames the repo's own branch.
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

    /// Git keeps a ref in a file, so a branch cannot be both a name and a folder of names. Both
    /// directions are knowable from the same set the exact-match check already reads.
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

    /// The conflict can sit any number of segments up, not just at the first one.
    func test_aDeepNameUnderAnExistingBranch_namesTheBranchInTheWay() throws {
        let (overlay, _) = mount(branches: ["feature/zen"])

        branchField(in: overlay).setText("feature/zen/473")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(
            inlineMessage(in: overlay), "feature/zen is already a branch, so this can't be a folder.")
    }

    /// A shared prefix that is not a whole path segment is not a conflict.
    func test_aNameSharingAPrefixButNotASegment_isFine() throws {
        let (overlay, sink) = mount(branches: ["test/branch-test"])

        branchField(in: overlay).setText("testing")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(sink.submitted.first, .newBranch("testing", .defaultBranch))
    }

    // MARK: submit

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

    // MARK: the create's own state

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

    // MARK: the base captions name the ref

    func test_theBaseCaption_namesTheRefEachChoiceCutsFrom() throws {
        let (overlay, _) = mount(defaultBase: "origin/main", currentBranch: "feature/zen-455")

        XCTAssertTrue(visibleText(in: overlay).contains("Starts from origin/main."))
        try XCTUnwrap(segment(in: overlay)).select(1)
        XCTAssertTrue(visibleText(in: overlay).contains("Starts from feature/zen-455."))
    }

    /// A detached checkout and a repo with no remote leave nothing to name.
    func test_withNothingToName_theCaptionStillSaysWhichChoiceItIs() throws {
        let (overlay, _) = mount(defaultBase: nil, currentBranch: nil)

        XCTAssertTrue(visibleText(in: overlay).contains("Starts from the default branch."))
        try XCTUnwrap(segment(in: overlay)).select(1)
        XCTAssertTrue(visibleText(in: overlay).contains("Starts from this checkout."))
    }

    // MARK: the phase line

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

    /// Clicking out is a way out, not a way back. Esc and Cancel return to the list; this does not.
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

    /// The base the caption describes has to stay the base that was submitted.
    func test_whileWorking_theBaseSegmentIsLocked() throws {
        let (overlay, _) = mount()
        let base = try XCTUnwrap(segment(in: overlay))

        overlay.beginWork("Creating spike")

        // The flag is not the lock: `NSButton` is what refuses the click, so assert on the segments.
        XCTAssertEqual(segmentButtons(in: base).filter(\.isEnabled), [])
        XCTAssertFalse(base.acceptsFirstResponder)
        XCTAssertTrue(visibleText(in: overlay).contains("Starts from origin/main."))

        overlay.failWork("nope")

        XCTAssertEqual(segmentButtons(in: base).filter { !$0.isEnabled }, [], "and it comes back")
        XCTAssertTrue(base.acceptsFirstResponder)
    }

    /// The message named a branch the user has since retyped.
    func test_typingAfterAFailure_clearsTheError() throws {
        let (overlay, _) = mount()
        overlay.beginWork("Creating spike")
        overlay.failWork("That branch already exists.")

        branchField(in: overlay).setText("spike-2")
        branchField(in: overlay).onChange?()

        XCTAssertFalse(visibleText(in: overlay).contains("That branch already exists."))
    }

    // MARK: carry

    func test_theCopyLine_namesWhatComesAcross() throws {
        let (overlay, _) = mount(carry: ["node_modules", ".env"])

        XCTAssertTrue(visibleText(in: overlay).contains("node_modules, .env"))
    }

    /// The button carries the whole message when nothing is set, so there is no line to read.
    func test_withNoCarryConfigured_thereIsOnlyTheButton() throws {
        let (overlay, _) = mount(carry: [])

        XCTAssertNotNil(button(in: overlay, title: "Choose what to copy"))
        XCTAssertFalse(visibleText(in: overlay).contains("Nothing set"))
    }

    /// Carry belongs to the workspace, not to this create, so the card sends you to the form that
    /// owns it. Without the button the empty state names a place with no way to get there.
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

    /// A host with nowhere to send it leaves the button off rather than showing a dead one.
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

    /// A create in flight locks every control; a card torn down early leaves a worktree landing
    /// with nothing to report to.
    func test_aCreateInFlight_locksTheCopyButton() throws {
        let (overlay, sink) = mount(carry: [])
        let copyButton = try XCTUnwrap(button(in: overlay, title: "Choose what to copy"))

        overlay.beginWork("Creating spike")
        copyButton.onTap()

        XCTAssertFalse(copyButton.isEnabled)
        XCTAssertEqual(sink.editedWorkspace, 0)
    }

    // MARK: keyboard

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

    /// Cancel is not in `verticalStops`, so Up from it has to resolve through Create.
    func test_upFromCancel_reachesTheCopyButton() throws {
        let (overlay, _) = mount()
        let copyButton = try XCTUnwrap(button(in: overlay, title: "Choose what to copy"))
        let cancel = try XCTUnwrap(button(in: overlay, title: "Cancel"))
        window?.makeFirstResponder(cancel)

        cancel.keyDown(with: try arrow(down: false))

        XCTAssertTrue(KeyboardFocus.isFocused(copyButton, in: window))
    }

    // MARK: harness

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

    /// Types through the real field so the live validation pass runs, the way a keystroke does.
    private func type(_ text: String, into overlay: NSView) {
        let box = branchField(in: overlay)
        box.setText(text)
        box.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: box.field))
    }

    /// Both cards carry a Create Worktree and a Cancel, so a confirm's buttons are looked up
    /// inside it rather than by title across the whole overlay.
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

    /// Every label on screen. An editable field holds the typed value, not copy.
    private func visibleText(in overlay: NSView) -> [String] {
        descendants(of: overlay)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
            .map(\.stringValue)
    }

    /// The inline validation message. The caption is a `FieldCaption` and the field is editable,
    /// so neither is mistaken for it.
    private func inlineMessage(in overlay: NSView) -> String? {
        guard let group = descendants(of: overlay).compactMap({ $0 as? LabeledField }).first
        else { return nil }
        return descendants(of: group)
            .compactMap { $0 as? NSTextField }
            .first { !($0 is FieldCaption) && !$0.isEditable && !$0.isHidden }?
            .stringValue
    }

    /// AppKit hangs `.function` and `.numericPad` on every arrow; without them this is a
    /// keystroke macOS never sends.
    private func arrow(down: Bool) throws -> NSEvent {
        let character = String(UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!)
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                timestamp: 0, windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false,
                keyCode: down ? 125 : 126))
    }

    /// `NSWindow.sendEvent`'s path: a traversal from the content view, where the card claims it.
    @discardableResult
    private func pressEscape() -> Bool {
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        return window!.contentView!.performKeyEquivalent(with: esc)
    }
}
