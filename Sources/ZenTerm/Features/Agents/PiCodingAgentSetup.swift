import AgentSetup
import Foundation

enum PiCodingAgentSetup: SetupAgent {
    typealias Installer = PiSetup

    static let declinedKey = "PiSetupOfferDeclined"
    static let skippedVersionKey = "PiSetupUpdateSkippedVersion"

    #if DEBUG
        static var configRootOverrideForTesting: URL?
        static var filesOverrideForTesting: PiSetupFiles?
    #endif
}
