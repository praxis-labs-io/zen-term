import AgentSetup
import Foundation

// An agent zen sets up; each install, refresh and check runs off main because it reads or writes the agent's folder.
protocol SetupAgent {
    associatedtype Installer: AgentInstaller

    static var declinedKey: String { get }
    static var skippedVersionKey: String { get }

    #if DEBUG
        static var configRootOverrideForTesting: URL? { get }
        static var filesOverrideForTesting: Installer.Files? { get }
    #endif
}

enum SetupChange { case install, remove }

enum SetupStartup: Equatable {
    case notInstalled
    case updated
    case updateFailed(SetupError)
    case edited(version: String)
    case current
}

private let setupQueue = DispatchQueue(label: "com.zenterm.agent-setup", qos: .userInitiated)

extension SetupAgent {
    // The app's own environment, which a Finder or Dock launch does not take from the shell profile.
    static var configRoot: URL {
        #if DEBUG
            if let configRootOverrideForTesting { return configRootOverrideForTesting }
        #endif
        return Installer.configRoot(environment: ProcessInfo.processInfo.environment)
    }

    static var folderName: String { PathDisplay.abbreviatingHome(configRoot.path) }

    static func refresh(
        applying change: SetupChange? = nil, completion: @escaping (Result<SetupState, SetupError>) -> Void
    ) {
        perform(completion: completion) { setup throws(SetupError) in
            switch change {
            case .install: _ = try setup.install()
            case .remove: _ = try setup.remove()
            case nil: break
            }
            return try setup.state()
        }
    }

    static func agentStarted(completion: @escaping (Result<SetupStartup, SetupError>) -> Void) {
        perform(completion: completion) { setup throws(SetupError) in
            switch try setup.state() {
            case .notInstalled: return .notInstalled
            case .edited: return .edited(version: setup.files.version)
            case .current, .newer: return .current
            case .outdated:
                do throws(SetupError) {
                    _ = try setup.install()
                    return .updated
                } catch {
                    return .updateFailed(error)
                }
            }
        }
    }

    private static func perform<Outcome>(
        completion: @escaping (Result<Outcome, SetupError>) -> Void,
        _ work: @escaping (Installer) throws(SetupError) -> Outcome
    ) {
        let configRoot = configRoot
        var files: Installer.Files?
        #if DEBUG
            files = filesOverrideForTesting
        #endif
        setupQueue.async {
            let result = Result { () throws(SetupError) -> Outcome in
                guard let files = files ?? Installer.Files.bundled(beside: Bundle.main.executableURL) else {
                    throw SetupError(message: "ZenTerm can't find the skill it ships with. Reinstall ZenTerm.")
                }
                return try work(Installer(configRoot: configRoot, files: files))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
