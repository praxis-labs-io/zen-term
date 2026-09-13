import AppKit
import AppLog
import Sparkle

// No `SPUStandardUserDriver` fallback: `SUEnableAutomaticChecks` in the plist suppresses Sparkle's permission prompt.
final class ZenUpdateDriver: NSObject, SPUUserDriver {
    // Weak and set late: `UpdateController` builds the `SPUUpdater` from this driver.
    weak var controller: UpdateController?

    private var expectedLength: UInt64?
    private var receivedLength: UInt64 = 0

    // Captured at `showUpdateFound` because `showReady` carries no appcast item.
    private var pendingVersion: String?

    // A manual check reports a no-update result; a scheduled one stays silent.
    private var userInitiated = false

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void
    ) {
        reply(.init(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
        Log.info("manual update check started", category: .update)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
    ) {
        pendingVersion = appcastItem.displayVersionString
        userInitiated = false
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
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        Log.info("no update available: \(error.localizedDescription)", category: .update)
        controller?.dismiss()
        if userInitiated {
            userInitiated = false
            controller?.announce(
                ToastContent(
                    variant: .positive, title: "You're on the latest",
                    message: "ZenTerm \(AppVersion.current)"))
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
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

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = nil
        receivedLength = 0
        Log.info("update download started", category: .update)
        controller?.present(state: .downloading(fraction: nil), actions: .init())
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
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

    // Sparkle fires this continuously through extraction, so only start and finish are logged.
    func showExtractionReceivedProgress(_ progress: Double) {
        if progress <= 0 || progress >= 1 {
            Log.info("update extraction progress: \(Int(progress * 100))%", category: .update)
        }
        controller?.present(state: .downloading(fraction: progress), actions: .init())
    }

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

    private var downloadFraction: Double? {
        guard let expectedLength, expectedLength > 0 else { return nil }
        return Double(receivedLength) / Double(expectedLength)
    }

    // Every card button shares one Sparkle reply, which must fire exactly once.
    static func fireOnce(
        _ reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
    ) -> (SPUUserUpdateChoice) -> Void {
        var fired = false
        return { choice in
            guard !fired else {
                Log.info("update choice ignored, already answered: \(Self.label(choice))", category: .update)
                return
            }
            fired = true
            Log.info("update choice forwarded to Sparkle: \(Self.label(choice))", category: .update)
            reply(choice)
        }
    }

    private static func label(_ choice: SPUUserUpdateChoice) -> String {
        switch choice {
        case .install: return "install"
        case .dismiss: return "dismiss"
        case .skip: return "skip"
        @unknown default: return "unknown"
        }
    }

    private static func label(_ stage: SPUUserUpdateStage) -> String {
        switch stage {
        case .notDownloaded: return "not-downloaded"
        case .downloaded: return "downloaded"
        case .installing: return "installing"
        @unknown default: return "unknown"
        }
    }

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
