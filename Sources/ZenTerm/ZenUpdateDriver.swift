import AppKit
import AppLog
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

    /// The version being installed, captured from the appcast item at `showUpdateFound`. The later
    /// `showReady` callback carries no appcast item, so without this the ready card would name
    /// `AppVersion.current` — the old, still-running version — instead of the update's target.
    private var pendingVersion: String?

    /// True while a user-initiated check ("Check for Updates", ZEN-20) is in flight. A manual check
    /// reports its result even when nothing's found (an up-to-date / failure toast); a scheduled one
    /// stays silent. Set at `showUserInitiatedUpdateCheck`, cleared once the outcome is delivered.
    private var userInitiated = false

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
        // The "Check for Updates" command started this check (ZEN-20). Remember it so the outcome
        // reports back — an up-to-date or failure toast a scheduled check would swallow silently.
        userInitiated = true
        Log.info("manual update check started", category: .update)
    }

    // MARK: - Update found → the "available" card

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
    ) {
        pendingVersion = appcastItem.displayVersionString
        userInitiated = false  // the card carries the result now; no separate toast
        Log.info(
            "update found: \(appcastItem.displayVersionString) (stage \(Self.label(state.stage)))",
            category: .update)
        let choose = Self.fireOnce(reply)
        var actions = UpdateCardView.Actions()
        actions.install = { choose(.install) }
        actions.later = { choose(.dismiss) }
        actions.skip = { choose(.skip) }
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
        // Unconditional (ZEN-248): a scheduled check that finds nothing left no trace at all.
        Log.info("no update available: \(error.localizedDescription)", category: .update)
        controller?.dismiss()
        if userInitiated {
            userInitiated = false
            controller?.announce(
                ToastContent(
                    variant: .info, title: "You're on the latest",
                    message: "ZenTerm \(AppVersion.current)"))
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        // Unconditional (ZEN-248): before this, a failure after Install produced no card, no toast,
        // and no log line — the reason the report couldn't be traced in a diagnostics bundle.
        Log.warning("update failed: \(error.localizedDescription)", category: .update)
        controller?.dismiss()
        if userInitiated {
            userInitiated = false
            controller?.announce(
                ToastContent(
                    variant: .warning, title: "Couldn't check for updates",
                    message: "Something went wrong. Try again later."))
        }
        acknowledgement()
    }

    // MARK: - Download / extract → the progress card

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = nil
        receivedLength = 0
        Log.info("update download started", category: .update)
        controller?.present(state: .downloading(fraction: nil), actions: .init())
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        // Logged once here, not per chunk: showDownloadDidReceiveData fires hundreds of times.
        Log.info("update download expected length: \(expectedContentLength) bytes", category: .update)
        controller?.present(state: .downloading(fraction: downloadFraction), actions: .init())
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        controller?.present(state: .downloading(fraction: downloadFraction), actions: .init())
    }

    func showDownloadDidStartExtractingUpdate() {
        Log.info("update download complete, extracting", category: .update)
        controller?.present(state: .downloading(fraction: nil), actions: .init())
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        // Start and finish only — Sparkle fires this continuously through extraction.
        if progress <= 0 || progress >= 1 {
            Log.info("update extraction progress: \(Int(progress * 100))%", category: .update)
        }
        controller?.present(state: .downloading(fraction: progress), actions: .init())
    }

    // MARK: - Ready → the relaunch card

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        Log.info("update ready to install: \(pendingVersion ?? AppVersion.current)", category: .update)
        let choose = Self.fireOnce(reply)
        var actions = UpdateCardView.Actions()
        actions.relaunch = { choose(.install) }
        actions.later = { choose(.dismiss) }
        controller?.present(
            state: .ready(version: pendingVersion ?? AppVersion.current), actions: actions)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        // The app is quitting to install; the card goes with it. Nothing to morph.
        Log.info("update installing (app terminated: \(applicationTerminated))", category: .update)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        Log.info("update installed and relaunched: \(relaunched)", category: .update)
        controller?.dismiss()
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        Log.info("update installation dismissed", category: .update)
        controller?.dismiss()
    }

    // MARK: - Helpers

    /// The download fraction, or nil while the total is unknown (an indeterminate sweep).
    private var downloadFraction: Double? {
        guard let expectedLength, expectedLength > 0 else { return nil }
        return Double(receivedLength) / Double(expectedLength)
    }

    /// Wrap a Sparkle reply so it fires at most once. Every button on the card closes over the same
    /// one-shot reply and all three stay live until the card morphs, so a double-tap (or Install then
    /// Skip) would otherwise call reply twice and break Sparkle's exactly-once contract. Sparkle
    /// invokes the driver on the main thread and taps land there too, so the plain flag is safe.
    static func fireOnce(
        _ reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
    ) -> (SPUUserUpdateChoice) -> Void {
        var fired = false
        return { choice in
            guard !fired else {
                // ZEN-248: a swallowed repeat. Paired with the tap log, this separates "clicked five
                // times, forwarded once" (working as designed) from "clicked five, forwarded zero".
                Log.info("update choice ignored, already answered: \(Self.label(choice))", category: .update)
                return
            }
            fired = true
            Log.info("update choice forwarded to Sparkle: \(Self.label(choice))", category: .update)
            reply(choice)
        }
    }

    /// A non-sensitive label for a Sparkle choice, for the diagnostic log (ZEN-248).
    private static func label(_ choice: SPUUserUpdateChoice) -> String {
        switch choice {
        case .install: return "install"
        case .dismiss: return "dismiss"
        case .skip: return "skip"
        @unknown default: return "unknown"
        }
    }

    /// A non-sensitive label for the update's stage at `showUpdateFound` — it changes what `.install`
    /// does inside Sparkle (resume a downloaded update vs. start one), so the log names it (ZEN-248).
    private static func label(_ stage: SPUUserUpdateStage) -> String {
        switch stage {
        case .notDownloaded: return "not-downloaded"
        case .downloaded: return "downloaded"
        case .installing: return "installing"
        @unknown default: return "unknown"
        }
    }

    /// Pull the bulleted lines out of the appcast `<description>`. The release pipeline feeds this a
    /// short list (the notes file's `<!-- card ... -->` block), so this keeps only lines marked
    /// "- " / "* " (stripped) and ignores any stray prose — "What's new" links the full notes for
    /// anyone who wants them. Capped so a long list can't grow the card without bound.
    static func bullets(from description: String?) -> [String] {
        guard let description else { return [] }
        return
            description
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { line -> String? in
                guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .prefix(6)
            .map { $0 }
    }
}
