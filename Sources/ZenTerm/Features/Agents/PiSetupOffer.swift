import Foundation

// Whether Pi starting should offer setup, or say an older install was updated: once a launch.
final class PiSetupOffer {
    static let declinedKey = "PiSetupOfferDeclined"
    static let skippedVersionKey = "PiSetupUpdateSkippedVersion"

    private let defaults: UserDefaults
    private var hasChecked = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func piStarted(show: @escaping (PiCodeSetup.Startup) -> Void) {
        guard !hasChecked else { return }
        hasChecked = true
        PiCodeSetup.piStarted { [weak self] result in
            guard let self, case .success(let startup) = result, isShown(startup) else { return }
            show(startup)
        }
    }

    func declineForGood() { defaults.set(true, forKey: Self.declinedKey) }

    func skipUpdate(to version: String) { defaults.set(version, forKey: Self.skippedVersionKey) }

    private func isShown(_ startup: PiCodeSetup.Startup) -> Bool {
        switch startup {
        case .notInstalled: !defaults.bool(forKey: Self.declinedKey)
        case .edited(let version):
            !defaults.bool(forKey: Self.declinedKey) && defaults.string(forKey: Self.skippedVersionKey) != version
        case .updated, .updateFailed: true
        case .current: false
        }
    }
}
