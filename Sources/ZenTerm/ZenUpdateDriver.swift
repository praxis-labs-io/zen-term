import AppKit
import Sparkle

/// Drives Sparkle's user-facing moments into the one `UpdateCardView` (ZEN-118). Sparkle keeps the
/// appcast fetch, EdDSA check, download and install; we own every pixel. Sparkle invokes these on the
/// main thread, so each one maps the callback to a card state and routes it to `UpdateController`.
///
/// There is no `SPUStandardUserDriver` fallback: `SUEnableAutomaticChecks = true` in the packaged
/// plist suppresses the stock permission prompt, and the card only ever surfaces the success path
/// (an available update, its download, and the relaunch). A failed or empty automatic check stays
/// silent — nothing was asked, so nothing is answered.
final class ZenUpdateDriver: NSObject, SPUUserDriver {
    /// Weak + set after construction: the `UpdateController` builds the `SPUUpdater` from this
    /// driver, so the driver can't hold it at init without a retain cycle or a chicken-and-egg.
    weak var controller: UpdateController?

    /// Download accounting for the progress bar. Reset when a download starts; `expectedLength` is
    /// nil until Sparkle reports it, which the bar renders as an indeterminate sweep.
    private var expectedLength: UInt64?
    private var receivedLength: UInt64 = 0

    // MARK: - Permission / check (no card)

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void
    ) {
        // Automatic checks are enabled in the plist, so this normally isn't reached; grant them
        // without a prompt if it ever is. No system profile — we send nothing about the machine.
        reply(.init(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // No manual "Check for Updates" entry point yet (ZEN-173); only scheduled checks run.
    }

    // MARK: - Update found → the "available" card

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
    ) {
        var actions = UpdateCardView.Actions()
        actions.install = { reply(.install) }
        actions.later = { reply(.dismiss) }
        actions.skip = { reply(.skip) }
        actions.whatsNew = { NSWorkspace.shared.open($0) }
        controller?.present(
            state: .available(
                version: appcastItem.displayVersionString,
                current: "You're on \(AppVersion.current)",
                notes: Self.bullets(from: appcastItem.itemDescription),
                notesURL: appcastItem.releaseNotesURL),
            actions: actions)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The notes come straight off the appcast item's <description>, so the downloaded release-
        // notes payload is unused.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // See showUpdateReleaseNotes — nothing depends on the downloaded notes.
    }

    // MARK: - Nothing to show (stay silent)

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        controller?.dismiss()
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        controller?.dismiss()
        acknowledgement()
    }

    // MARK: - Download / extract → the progress card

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = nil
        receivedLength = 0
        controller?.present(state: .downloading(fraction: nil), actions: .init())
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        controller?.present(state: .downloading(fraction: downloadFraction), actions: .init())
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        controller?.present(state: .downloading(fraction: downloadFraction), actions: .init())
    }

    func showDownloadDidStartExtractingUpdate() {
        controller?.present(state: .downloading(fraction: nil), actions: .init())
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        controller?.present(state: .downloading(fraction: progress), actions: .init())
    }

    // MARK: - Ready → the relaunch card

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        var actions = UpdateCardView.Actions()
        actions.relaunch = { reply(.install) }
        actions.later = { reply(.dismiss) }
        controller?.present(
            state: .ready(version: AppVersion.current), actions: actions)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        // The app is quitting to install; the card goes with it. Nothing to morph.
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        controller?.dismiss()
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        controller?.dismiss()
    }

    // MARK: - Helpers

    /// The download fraction, or nil while the total is unknown (an indeterminate sweep).
    private var downloadFraction: Double? {
        guard let expectedLength, expectedLength > 0 else { return nil }
        return Double(receivedLength) / Double(expectedLength)
    }

    /// Split the appcast `<description>` (curated markdown bullets) into plain bullet strings. The
    /// release pipeline drops the notes file in as-is, so we strip a leading "- " / "* " and cap the
    /// list — "What's new" links the full notes for anyone who wants them.
    static func bullets(from description: String?) -> [String] {
        guard let description else { return [] }
        return
            description
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { line -> String? in
                guard line.hasPrefix("- ") || line.hasPrefix("* ") else {
                    return line.isEmpty ? nil : line
                }
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .prefix(6)
            .map { $0 }
    }
}
