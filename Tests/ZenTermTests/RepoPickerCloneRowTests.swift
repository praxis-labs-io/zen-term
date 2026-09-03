import AppKit
import XCTest

@testable import ZenTerm

/// The clone rows in ⌘P: how they sit under their parent, and `selectedWorkspace`, the seam
/// `WindowController` reads to resolve ⌥⏎ into "clone this row" (see `WindowControllerCloneChordTests`
/// for the keyboard path itself).
final class RepoPickerCloneRowTests: WindowTestCase {
    private static let moveDown = #selector(NSResponder.moveDown(_:))
    private static let moveUp = #selector(NSResponder.moveUp(_:))

    /// Retained so a mounted overlay's window outlives the mount call.
    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        GitRepoStatus.resetForTesting()
    }

    override func tearDown() {
        window = nil
        GitRepoStatus.resetForTesting()
        super.tearDown()
    }

    // MARK: fixtures

    private func workspace(_ title: String) -> Workspace {
        Workspace(
            title: title, path: URL(fileURLWithPath: "/tmp/\(title)"), main: "nvim", right: "claude",
            bottom: nil, focus: .right, env: ["KEY": "value"])
    }

    private func clone(_ parent: String, _ name: String) -> Clone {
        Clone(
            workspaceTitle: parent, name: name,
            path: URL(fileURLWithPath: "/tmp/clones/\(parent)/\(name)"),
            branch: "\(parent.lowercased())-\(name)")
    }

    private func makePicker(
        entries: [Workspace], clones: [Clone],
        onChoose: @escaping (Workspace, Bool) -> Void = { _, _ in }
    ) -> RepoPickerOverlay {
        RepoPickerOverlay(
            entries: entries, clones: clones, background: Theme.current.chrome.background.nsColor,
            onChoose: onChoose, onAddWorkspace: {}, onDismiss: {})
    }

    @discardableResult
    private func mount(_ overlay: RepoPickerOverlay) -> NSWindow {
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        self.window = window
        return window
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func searchField(in overlay: RepoPickerOverlay) -> NSTextField {
        descendants(of: overlay).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
    }

    @discardableResult
    private func send(_ selector: Selector, to overlay: RepoPickerOverlay) -> Bool {
        overlay.control(searchField(in: overlay), textView: NSTextView(), doCommandBy: selector)
    }

    private func type(_ query: String, into overlay: RepoPickerOverlay) {
        searchField(in: overlay).stringValue = query
        overlay.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: searchField(in: overlay)))
    }

    /// The rendered row labels, top to bottom: the ＋ row, then a title per workspace or clone.
    private func rowTitles(in overlay: RepoPickerOverlay) -> [String] {
        overlay.rowViews.map { row in
            descendants(of: row).compactMap { ($0 as? NSTextField)?.stringValue }.first ?? ""
        }
    }

    // MARK: rows

    func test_clonesRenderUnderTheirParentInOrder() {
        let overlay = makePicker(
            entries: [workspace("alpha"), workspace("beta")],
            clones: [clone("beta", "c2"), clone("alpha", "c2"), clone("alpha", "c3")])
        mount(overlay)

        XCTAssertEqual(
            rowTitles(in: overlay),
            ["New Workspace…", "alpha", "alpha c2", "alpha c3", "beta", "beta c2"])
    }

    func test_cloneRowShowsItsBranch() throws {
        let overlay = makePicker(entries: [workspace("alpha")], clones: [clone("alpha", "c2")])
        mount(overlay)

        let row = overlay.rowViews.compactMap { $0 as? RepoPickerOverlay.CloneRowView }.first
        let labels = descendants(of: try XCTUnwrap(row)).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertEqual(labels, ["alpha c2", "alpha-c2"])
    }

    func test_rowIdentitiesAreDistinctPerClone() {
        let overlay = makePicker(
            entries: [workspace("alpha")], clones: [clone("alpha", "c2"), clone("alpha", "c3")])
        mount(overlay)

        let identities = (0..<overlay.numberOfRows()).compactMap { overlay.rowIdentity(at: $0) }
        XCTAssertEqual(identities.count, Set(identities).count)
    }

    func test_filteringOnACloneKeepsItsParentRow() {
        let overlay = makePicker(
            entries: [workspace("alpha"), workspace("beta")],
            clones: [clone("alpha", "c2"), clone("beta", "c2")])
        mount(overlay)

        type("alpha c2", into: overlay)

        XCTAssertEqual(rowTitles(in: overlay), ["New Workspace…", "alpha", "alpha c2"])
    }

    // MARK: opening a clone (⏎)

    func test_returnOnACloneOpensTheParentRecipeAtTheClonePath() throws {
        var chosen: (Workspace, Bool)?
        let overlay = makePicker(
            entries: [workspace("alpha")], clones: [clone("alpha", "c2")],
            onChoose: { chosen = ($0, $1) })
        mount(overlay)

        send(Self.moveDown, to: overlay)  // off the workspace row, onto its clone
        send(#selector(NSResponder.insertNewline(_:)), to: overlay)

        XCTAssertEqual(chosen?.0.title, "alpha c2")
        XCTAssertEqual(chosen?.0.path, URL(fileURLWithPath: "/tmp/clones/alpha/c2"))
        XCTAssertEqual(chosen?.0.main, "nvim")
        XCTAssertEqual(chosen?.0.right, "claude")
        XCTAssertEqual(chosen?.0.focus, .right)
        XCTAssertEqual(chosen?.0.env, ["KEY": "value"])
    }

    // MARK: selectedWorkspace — what ⌥⏎ resolves against

    func test_selectedWorkspace_isTheDefaultSelectionOnOpen() {
        let overlay = makePicker(entries: [workspace("alpha"), workspace("beta")], clones: [])
        mount(overlay)

        XCTAssertEqual(overlay.selectedWorkspace?.title, "alpha")
    }

    func test_selectedWorkspace_isNilOnTheAddRow() {
        let overlay = makePicker(entries: [workspace("alpha")], clones: [])
        mount(overlay)

        send(Self.moveUp, to: overlay)  // onto the pinned ＋ row

        XCTAssertNil(overlay.selectedWorkspace)
    }

    func test_selectedWorkspace_isNilOnACloneRow() {
        let overlay = makePicker(entries: [workspace("alpha")], clones: [clone("alpha", "c2")])
        mount(overlay)

        send(Self.moveDown, to: overlay)  // onto the clone

        XCTAssertNil(overlay.selectedWorkspace)
    }

    func test_selectedWorkspace_tracksArrowMovement() {
        let overlay = makePicker(entries: [workspace("alpha"), workspace("beta")], clones: [])
        mount(overlay)

        send(Self.moveDown, to: overlay)

        XCTAssertEqual(overlay.selectedWorkspace?.title, "beta")
    }

    // MARK: pending clones

    func test_beginPendingClone_rendersAPlaceholderUnderItsParent() {
        let overlay = makePicker(entries: [workspace("alpha"), workspace("beta")], clones: [])
        mount(overlay)

        overlay.beginPendingClone(for: workspace("alpha"))

        XCTAssertEqual(rowTitles(in: overlay), ["New Workspace…", "alpha", "Cloning…", "beta"])
        XCTAssertTrue(overlay.rowViews[2] is RepoPickerOverlay.PendingCloneRowView)
    }

    func test_beginPendingClone_leavesSelectionOnTheClonedRow_notTheTop() {
        let overlay = makePicker(
            entries: [workspace("alpha"), workspace("beta"), workspace("gamma")], clones: [])
        mount(overlay)
        send(Self.moveDown, to: overlay)
        send(Self.moveDown, to: overlay)  // onto "gamma", away from the default top selection

        overlay.beginPendingClone(for: workspace("gamma"))

        XCTAssertEqual(overlay.selectedWorkspace?.title, "gamma")
    }

    func test_completePendingClone_alsoLeavesSelectionInPlace() {
        let overlay = makePicker(
            entries: [workspace("alpha"), workspace("beta"), workspace("gamma")], clones: [])
        mount(overlay)
        send(Self.moveDown, to: overlay)
        send(Self.moveDown, to: overlay)  // onto "gamma"
        let id = overlay.beginPendingClone(for: workspace("gamma"))

        overlay.completePendingClone(id, with: clone("gamma", "c2"))

        XCTAssertEqual(overlay.selectedWorkspace?.title, "gamma")
    }

    func test_pendingRow_isNotSelectable() {
        let overlay = makePicker(entries: [workspace("alpha")], clones: [])
        mount(overlay)
        overlay.beginPendingClone(for: workspace("alpha"))

        send(Self.moveDown, to: overlay)  // would land on the pending row if it were selectable

        // Nothing past it to land on instead — selection holds on "alpha".
        XCTAssertEqual(overlay.selectedWorkspace?.title, "alpha")
    }

    func test_completePendingClone_replacesThePlaceholderWithTheRealRow() {
        let overlay = makePicker(entries: [workspace("alpha")], clones: [])
        mount(overlay)
        let id = overlay.beginPendingClone(for: workspace("alpha"))

        overlay.completePendingClone(id, with: clone("alpha", "c2"))

        XCTAssertEqual(rowTitles(in: overlay), ["New Workspace…", "alpha", "alpha c2"])
        XCTAssertFalse(overlay.rowViews.contains { $0 is RepoPickerOverlay.PendingCloneRowView })
    }

    func test_failPendingClone_removesThePlaceholderWithNoReplacement() {
        let overlay = makePicker(entries: [workspace("alpha")], clones: [])
        mount(overlay)
        let id = overlay.beginPendingClone(for: workspace("alpha"))

        overlay.failPendingClone(id)

        XCTAssertEqual(rowTitles(in: overlay), ["New Workspace…", "alpha"])
    }

    func test_beginPendingClone_survivesTheCurrentFilter() {
        let overlay = makePicker(entries: [workspace("alpha"), workspace("beta")], clones: [])
        mount(overlay)
        type("alpha", into: overlay)

        overlay.beginPendingClone(for: workspace("alpha"))

        XCTAssertEqual(rowTitles(in: overlay), ["New Workspace…", "alpha", "Cloning…"])
    }

    /// A clone that lands while the picker is closed and reopened is already in the list this
    /// instance scanned from disk. Appending it again gives two rows one identity, and
    /// `reselect(byIdentity:)` cannot then tell them apart.
    func test_completePendingClone_doesNotDuplicateACloneAlreadyListed() {
        let existing = clone("alpha", "c2")
        let overlay = makePicker(entries: [workspace("alpha")], clones: [existing])
        mount(overlay)
        let id = overlay.beginPendingClone(for: workspace("alpha"))

        overlay.completePendingClone(id, with: existing)

        XCTAssertEqual(rowTitles(in: overlay), ["New Workspace…", "alpha", "alpha c2"])
        let identities = (0..<overlay.numberOfRows()).compactMap { overlay.rowIdentity(at: $0) }
        XCTAssertEqual(identities.count, Set(identities).count, "row identities stay unique")
    }
}
