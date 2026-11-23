import Foundation

// Whether Claude starting should offer setup, or say an older install was updated: once a launch. Main-thread only.
final class ClaudeSetupOffer {
    static let declinedKey = "ClaudeSetupOfferDeclined"
    static let skippedVersionKey = "ClaudeSetupUpdateSkippedVersion"

    private let defaults: UserDefaults
    private var hasChecked = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func claudeStarted(show: @escaping (ClaudeCodeSetup.Startup) -> Void) {
        guard !hasChecked else { return }
        hasChecked = true
        ClaudeCodeSetup.claudeStarted { [weak self] result in
            guard let self, case .success(let startup) = result, isShown(startup) else { return }
            show(startup)
        }
    }

    func declineForGood() {
        defaults.set(true, forKey: Self.declinedKey)
    }

    func skipUpdate(to version: String) {
        defaults.set(version, forKey: Self.skippedVersionKey)
    }

    private func isShown(_ startup: ClaudeCodeSetup.Startup) -> Bool {
        switch startup {
        case .notInstalled: !defaults.bool(forKey: Self.declinedKey)
        case .edited(let version):
            !defaults.bool(forKey: Self.declinedKey) && defaults.string(forKey: Self.skippedVersionKey) != version
        case .updated, .updateFailed: true
        case .current: false
        }
    }
}
