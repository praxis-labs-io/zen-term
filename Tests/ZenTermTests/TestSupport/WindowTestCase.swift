import AppKit
import XCTest

@testable import ZenTerm

class WindowTestCase: XCTestCase {
    /// Captured at init, before any setup hook can pin it.
    private let originalReduceMotion = Motion.isReduceMotionEnabled
    private let originalConnectAfter = MainActor.assumeIsolated { HostConnectView.after }
    private let originalConnectNow = MainActor.assumeIsolated { HostConnectView.now }

    // Fixtures open worktrees at never-created folders the removal check reads as deleted, and Settings writes ~/.claude.
    override func setUpWithError() throws {
        try super.setUpWithError()
        WorktreeStore.isRemovedOverrideForTesting = { _ in false }
        PointerRest.resetForTesting()
        MainActor.assumeIsolated { HostConnectView.after = { _, work in work() } }
        ClaudeCodeSetup.configRootOverrideForTesting = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-claude-\(UUID().uuidString)")
        RunOutput.folderOverrideForTesting = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-run-output-\(UUID().uuidString)")
    }

    /// Not `tearDown`, which runs first and would close windows before a subclass's own teardown.
    override func tearDownWithError() throws {
        try super.tearDownWithError()
        Self.closeAllWindows()
        Motion.isReduceMotionEnabled = originalReduceMotion
        MainActor.assumeIsolated {
            HostConnectView.after = originalConnectAfter
            HostConnectView.now = originalConnectNow
        }
        WorktreeStore.isRemovedOverrideForTesting = nil
        if let folder = RunOutput.folderOverrideForTesting { try? FileManager.default.removeItem(at: folder) }
        RunOutput.folderOverrideForTesting = nil
        PointerRest.resetForTesting()
        ClaudeCodeSetup.configRootOverrideForTesting.map { try? FileManager.default.removeItem(at: $0) }
        ClaudeCodeSetup.configRootOverrideForTesting = nil
    }

    @MainActor
    func toastTexts(in c: WindowController) -> [String] {
        guard let content = c.window.contentView else { return [] }
        return Self.descendants(of: content).compactMap { $0 as? ToastView }
            .flatMap { Self.descendants(of: $0).compactMap { ($0 as? NSTextField)?.stringValue } }
    }

    @MainActor
    func confirmTexts(in c: WindowController) -> [String] {
        guard let content = c.window.contentView else { return [] }
        return Self.descendants(of: content).compactMap { $0 as? ConfirmCard }
            .flatMap { Self.descendants(of: $0).compactMap { ($0 as? NSTextField)?.stringValue } }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Clears `isReleasedWhenClosed`, or `close()` over-releases a window `WindowController` still owns.
    static func closeAllWindows() {
        for window in NSApplication.shared.windows {
            window.isReleasedWhenClosed = false
            window.close()
        }
    }
}
