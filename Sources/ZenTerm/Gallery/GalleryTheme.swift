#if DEBUG
    import Foundation

    // Never broadcasts: that would publish theme.json under the config's theme name with these colors.
    @MainActor
    final class GalleryTheme {
        private(set) var isOverridden = false

        func apply(themeName: String) {
            var general = GeneralConfig.current
            general.themeName = themeName
            Theme.setCurrentForTesting(ConfigLoader.loadAppTheme(general: general))
            isOverridden = true
        }

        func configDidReload() { isOverridden = false }

        func restore() {
            guard isOverridden else { return }
            isOverridden = false
            AppConfig.reload()
        }
    }
#endif
