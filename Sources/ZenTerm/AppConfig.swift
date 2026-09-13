import Foundation

extension Notification.Name {
    static let configDidChange = Notification.Name("ZenTerm.configDidChange")
}

enum AppConfig {
    @MainActor
    static func loadAtLaunch() {
        GeneralConfig.reloadCurrent()
        Theme.reloadCurrent()
        SessionFontSize.seed(from: GeneralConfig.current)
    }

    /// Re-seeds the session font size before broadcasting, because observers run in registration order.
    @MainActor
    static func reload(force: Bool = false) {
        let oldConfig = GeneralConfig.current
        let oldTheme = Theme.current
        GeneralConfig.reloadCurrent()
        Theme.reloadCurrent()
        SessionFontSize.reseedIfBaseChanged(from: GeneralConfig.current)
        let change =
            force
            ? .all
            : ConfigChange.between(
                old: oldConfig, new: GeneralConfig.current, oldTheme: oldTheme,
                newTheme: Theme.current)
        NotificationCenter.default.post(
            name: .configDidChange, object: nil, userInfo: [ConfigChange.userInfoKey: change])
    }
}
