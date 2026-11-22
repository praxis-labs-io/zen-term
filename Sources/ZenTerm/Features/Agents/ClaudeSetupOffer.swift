import Foundation

// Whether to offer Claude Code setup when Claude starts: once a launch, while it is not installed and not declined. Main-thread only.
final class ClaudeSetupOffer {
    static let declinedKey = "ClaudeSetupOfferDeclined"

    private let defaults: UserDefaults
    private var hasChecked = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func claudeStarted(offer: @escaping () -> Void) {
        guard !hasChecked, !defaults.bool(forKey: Self.declinedKey) else { return }
        hasChecked = true
        ClaudeCodeSetup.refresh {
            guard case .success(.notInstalled) = $0 else { return }
            offer()
        }
    }

    func declineForGood() {
        defaults.set(true, forKey: Self.declinedKey)
    }
}
