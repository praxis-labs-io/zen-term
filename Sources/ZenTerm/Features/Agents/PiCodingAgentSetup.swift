import AgentSetup
import Foundation

// Pi as the app sets it up: the installer `zen setup pi` runs, and the offer's defaults keys.
enum PiCodingAgentSetup: SetupAgent {
    typealias Installer = PiSetup

    static let declinedKey = "PiSetupOfferDeclined"
    static let skippedVersionKey = "PiSetupUpdateSkippedVersion"

    #if DEBUG
        static var configRootOverrideForTesting: URL?
        static var filesOverrideForTesting: PiSetupFiles?
    #endif
}
