import AgentSetup

enum SetupStartup: Equatable {
    case notInstalled
    case updated
    case updateFailed(SetupError)
    case edited(version: String)
    case current
}
