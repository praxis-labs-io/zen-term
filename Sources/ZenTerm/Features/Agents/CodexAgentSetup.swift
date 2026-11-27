import AgentSetup
import Foundation

enum CodexAgentSetup: SetupAgent {
    typealias Installer = CodexSetup

    static let declinedKey = "CodexSetupOfferDeclined"
    static let skippedVersionKey = "CodexSetupUpdateSkippedVersion"

    #if DEBUG
        static var configRootOverrideForTesting: URL?
        static var filesOverrideForTesting: CodexSetupFiles?
    #endif
}
