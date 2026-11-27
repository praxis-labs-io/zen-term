import AgentSetup
import Foundation

// Codex as the app sets it up: the installer `zen setup codex` runs, and the offer's defaults keys.
enum CodexAgentSetup: SetupAgent {
    typealias Installer = CodexSetup

    static let declinedKey = "CodexSetupOfferDeclined"
    static let skippedVersionKey = "CodexSetupUpdateSkippedVersion"

    #if DEBUG
        static var configRootOverrideForTesting: URL?
        static var filesOverrideForTesting: CodexSetupFiles?
    #endif
}
