import AgentSetup
import Foundation

// The installer `zen setup claude` runs, kept off main because every call reads or writes files in ~/.claude.
enum ClaudeCodeSetup {
    enum Change { case install, remove }

    #if DEBUG
        static var configRootOverrideForTesting: URL?
        static var filesOverrideForTesting: ClaudeSetupFiles?
    #endif

    private static let queue = DispatchQueue(label: "com.zenterm.claude-setup", qos: .userInitiated)

    static func refresh(
        applying change: Change? = nil, completion: @escaping (Result<ClaudeSetup.State, ClaudeSetupError>) -> Void
    ) {
        var configRoot = ClaudeSetup.configRoot()
        var files: ClaudeSetupFiles?
        #if DEBUG
            configRoot = configRootOverrideForTesting ?? configRoot
            files = filesOverrideForTesting
        #endif
        queue.async {
            let result = Result { () throws(ClaudeSetupError) -> ClaudeSetup.State in
                guard let files = files ?? ClaudeSetupFiles.bundled() else {
                    throw ClaudeSetupError(message: "ZenTerm can't find the skill it ships with. Reinstall ZenTerm.")
                }
                let setup = ClaudeSetup(configRoot: configRoot, files: files)
                switch change {
                case .install: _ = try setup.install()
                case .remove: _ = try setup.remove()
                case nil: break
                }
                return try setup.state()
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
