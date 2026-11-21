@testable import ZenTerm

extension GeneralConfig {
    static var builtInWithStickyCards: GeneralConfig {
        var config = GeneralConfig.builtIn
        config.attentionToast = .sticky
        config.completionToast = .sticky
        return config
    }
}
