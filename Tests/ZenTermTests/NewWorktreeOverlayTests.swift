import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the create-a-worktree card, driven through the real controls in a window.
/// A state-only test would pass while a control was dead, which is the failure the project's
/// interaction-test rule exists to catch.
final class NewWorktreeOverlayTests: WindowTestCase {
    private final class Sink {
        var submitted: [(branch: String, base: WorktreeStore.Base)] = []
        var cancelled = 0
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

    func test_aBranchThatAlreadyExists_isRefusedBeforeSubmit() throws {
        let (overlay, sink) = mount(branches: ["feature/zen-473"])

        branchField(in: overlay).setText("feature/zen-473")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertTrue(sink.submitted.isEmpty)
        XCTAssertEqual(inlineMessage(in: overlay), "That branch already exists.")
    }

    /// `refs/heads/-m` passes `check-ref-format`, and `worktree add -b -m` then hands `-m` to git's
    /// own `git branch`, which has no `--` guard: the repo's checked-out branch gets renamed.
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

    // MARK: submit

    func test_submit_handsBackTheTrimmedBranchAndTheDefaultBase() throws {
        let (overlay, sink) = mount()

        branchField(in: overlay).setText("  feature/zen-473  ")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(sink.submitted.first?.branch, "feature/zen-473")
        XCTAssertEqual(sink.submitted.first?.base, .defaultBranch)
    }

    func test_theSecondBaseSegment_cutsFromTheCurrentCheckout() throws {
        let (overlay, sink) = mount()

        try XCTUnwrap(segment(in: overlay)).select(1)
        branchField(in: overlay).setText("spike")
        try XCTUnwrap(button(in: overlay, title: "Create Worktree")).onTap()

        XCTAssertEqual(sink.submitted.first?.base, .currentCheckout)
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

    /// A detached checkout has no branch name and a repo with no remote has no default, so the
    /// caption says which choice it is rather than naming a ref that does not exist.
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

    // MARK: carry

    func test_theCarryLine_namesWhatTheWorkspaceCarries() throws {
        let (overlay, _) = mount(carry: ["node_modules", ".env"])

        XCTAssertTrue(visibleText(in: overlay).contains("node_modules, .env"))
    }

    func test_withNoCarryConfigured_theLineSaysWhereToSetIt() throws {
        let (overlay, _) = mount(carry: [])

        XCTAssertTrue(
            visibleText(in: overlay).contains(
                "Nothing set. Add carry lines to this workspace to bring over what git ignores."))
    }

    // MARK: keyboard

    func test_downAndUp_walkTheBaseSegmentBetweenTheBranchFieldAndCreate() throws {
        let (overlay, _) = mount()
        let base = try XCTUnwrap(segment(in: overlay))
        let create = try XCTUnwrap(button(in: overlay, title: "Create Worktree"))
        window?.makeFirstResponder(base)

        base.keyDown(with: try arrow(down: true))
        XCTAssertTrue(KeyboardFocus.isFocused(create, in: window))

        create.keyDown(with: try arrow(down: false))
        XCTAssertTrue(KeyboardFocus.isFocused(base, in: window))
    }

    /// Cancel shares Create's vertical stop, so Up from Cancel has to leave the footer rather than
    /// dying on a stop the list does not hold.
    func test_upFromCancel_reachesTheBaseSegment() throws {
        let (overlay, _) = mount()
        let base = try XCTUnwrap(segment(in: overlay))
        let cancel = try XCTUnwrap(button(in: overlay, title: "Cancel"))
        window?.makeFirstResponder(cancel)

        cancel.keyDown(with: try arrow(down: false))

        XCTAssertTrue(KeyboardFocus.isFocused(base, in: window))
    }

    // MARK: harness

    private func mount(
        carry: [String] = [], branches: Set<String> = [], defaultBase: String? = "origin/main",
        currentBranch: String? = "feature/zen-455"
    ) -> (overlay: NewWorktreeOverlay, sink: Sink) {
        let sink = Sink()
        let workspace = Workspace(
            title: "ZenTerm", path: URL(fileURLWithPath: "/tmp/zenterm-fixture"),
            main: nil, right: nil, bottom: nil, focus: .main, env: [:], carry: carry)
        let overlay = NewWorktreeOverlay(
            workspace: workspace,
            options: WorktreeStore.CreateOptions(
                branches: branches, defaultBase: defaultBase, currentBranch: currentBranch),
            background: Theme.current.chrome.background.nsColor,
            onSubmit: { sink.submitted.append((branch: $0, base: $1)) },
            onCancel: { sink.cancelled += 1 })
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(overlay)
        overlay.frame = win.contentView!.bounds
        win.contentView?.layoutSubtreeIfNeeded()
        window = win
        return (overlay, sink)
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

    private func segment(in overlay: NSView) -> SegmentedControl? {
        descendants(of: overlay).compactMap { $0 as? SegmentedControl }.first
    }

    /// Every label on the card that is actually on screen. Editable fields are the typed value, not
    /// copy, and are left out.
    private func visibleText(in overlay: NSView) -> [String] {
        descendants(of: overlay)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
            .map(\.stringValue)
    }

    /// The branch field's inline validation message, read out of its `LabeledField`. The caption is
    /// a `FieldCaption` and the control's own text field is editable, so neither is mistaken for it.
    private func inlineMessage(in overlay: NSView) -> String? {
        guard let group = descendants(of: overlay).compactMap({ $0 as? LabeledField }).first
        else { return nil }
        return descendants(of: group)
            .compactMap { $0 as? NSTextField }
            .first { !($0 is FieldCaption) && !$0.isEditable && !$0.isHidden }?
            .stringValue
    }

    /// An arrow keyDown as AppKit delivers one: `.function` and `.numericPad` ride along, and a
    /// synthesized event without them is a keystroke macOS never sends.
    private func arrow(down: Bool) throws -> NSEvent {
        let character = String(UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!)
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                timestamp: 0, windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false,
                keyCode: down ? 125 : 126))
    }

    /// Esc the way `NSWindow.sendEvent` delivers it: a `performKeyEquivalent` traversal from the
    /// content view, which is where the card root claims it.
    @discardableResult
    private func pressEscape() -> Bool {
        let esc = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        return window!.contentView!.performKeyEquivalent(with: esc)
    }
}
