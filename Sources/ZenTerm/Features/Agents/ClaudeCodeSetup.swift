import AgentSetup
import Foundation

// The installer `zen setup claude` runs, kept off main because every call reads or writes files in Claude's folder.
enum ClaudeCodeSetup {
    enum Change { case install, remove }

    #if DEBUG
        static var configRootOverrideForTesting: URL?
        static var filesOverrideForTesting: ClaudeSetupFiles?
    #endif

    private static let queue = DispatchQueue(label: "com.zenterm.claude-setup", qos: .userInitiated)

    // The app's own environment, which a Finder or Dock launch does not take from the shell profile.
    static var configRoot: URL {
        #if DEBUG
            if let configRootOverrideForTesting { return configRootOverrideForTesting }
        #endif
        return ClaudeSetup.configRoot()
    }

    static var folderName: String { PathDisplay.abbreviatingHome(configRoot.path) }

    enum Startup: Equatable {
        case notInstalled
        case updated
        case updateFailed(ClaudeSetupError)
        case edited(version: String)
        case current
    }

    static func refresh(
        applying change: Change? = nil, completion: @escaping (Result<ClaudeSetup.State, ClaudeSetupError>) -> Void
    ) {
        perform(completion: completion) { setup throws(ClaudeSetupError) in
            switch change {
            case .install: _ = try setup.install()
            case .remove: _ = try setup.remove()
            case nil: break
            }
            return try setup.state()
        }
    }

    static func claudeStarted(completion: @escaping (Result<Startup, ClaudeSetupError>) -> Void) {
        perform(completion: completion) { setup throws(ClaudeSetupError) in
            switch try setup.state() {
            case .notInstalled: return .notInstalled
            case .edited: return .edited(version: setup.files.version)
            case .current, .newer: return .current
            case .outdated:
                do throws(ClaudeSetupError) {
                    _ = try setup.install()
                    return .updated
                } catch {
                    return .updateFailed(error)
                }
            }
        }
    }

    private static func perform<Outcome>(
        completion: @escaping (Result<Outcome, ClaudeSetupError>) -> Void,
        _ work: @escaping (ClaudeSetup) throws(ClaudeSetupError) -> Outcome
    ) {
        let configRoot = configRoot
        var files: ClaudeSetupFiles?
        #if DEBUG
            files = filesOverrideForTesting
        #endif
        queue.async {
            let result = Result { () throws(ClaudeSetupError) -> Outcome in
                guard let files = files ?? ClaudeSetupFiles.bundled() else {
                    throw ClaudeSetupError(message: "ZenTerm can't find the skill it ships with. Reinstall ZenTerm.")
                }
                return try work(ClaudeSetup(configRoot: configRoot, files: files))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
