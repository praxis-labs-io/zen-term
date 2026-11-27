import AgentSetup
import Foundation

// Whether Claude starting should offer setup, or say an older install was updated: once a launch. Main-thread only.
final class ClaudeSetupOffer {
    static let declinedKey = "ClaudeSetupOfferDeclined"
    static let skippedVersionKey = "ClaudeSetupUpdateSkippedVersion"

    private let defaults: UserDefaults
    let client: ClaudeSetup.Client
    private var declinedKey: String { client == .claude ? Self.declinedKey : "CodexSetupOfferDeclined" }
    private var skippedVersionKey: String {
        client == .claude ? Self.skippedVersionKey : "CodexSetupUpdateSkippedVersion"
    }
    private var hasChecked = false

    init(defaults: UserDefaults = .standard, client: ClaudeSetup.Client = .claude) {
        self.defaults = defaults
        self.client = client
    }

    func claudeStarted(show: @escaping (ClaudeCodeSetup.Startup) -> Void) {
        guard !hasChecked else { return }
        hasChecked = true
        ClaudeCodeSetup.claudeStarted(client: client) { [weak self] result in
            guard let self, case .success(let startup) = result, isShown(startup) else { return }
            show(startup)
        }
    }

    func declineForGood() {
        defaults.set(true, forKey: declinedKey)
    }

    func skipUpdate(to version: String) {
        defaults.set(version, forKey: skippedVersionKey)
    }

    private func isShown(_ startup: ClaudeCodeSetup.Startup) -> Bool {
        switch startup {
        case .notInstalled: !defaults.bool(forKey: declinedKey)
        case .edited(let version):
            !defaults.bool(forKey: declinedKey) && defaults.string(forKey: skippedVersionKey) != version
        case .updated, .updateFailed: true
        case .current: false
        }
    }
}
