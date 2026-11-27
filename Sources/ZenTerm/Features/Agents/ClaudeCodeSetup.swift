import AgentSetup
import Foundation

// Claude Code as the app sets it up: the installer `zen setup claude` runs, and the offer's defaults keys.
enum ClaudeCodeSetup: SetupAgent {
    typealias Installer = ClaudeSetup

    static let declinedKey = "ClaudeSetupOfferDeclined"
    static let skippedVersionKey = "ClaudeSetupUpdateSkippedVersion"

    #if DEBUG
        static var configRootOverrideForTesting: URL?
        static var filesOverrideForTesting: ClaudeSetupFiles?
    #endif
}
