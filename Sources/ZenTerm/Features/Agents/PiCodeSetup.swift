import AgentSetup
import Foundation

// The app-side wrapper around `PiSetup` keeps Pi's agent-directory I/O off the main thread.
enum PiCodeSetup {
    enum Change { case install, remove }

    #if DEBUG
        static var configRootOverrideForTesting: URL?
        static var filesOverrideForTesting: PiSetupFiles?
    #endif

    private static let queue = DispatchQueue(label: "com.zenterm.pi-setup", qos: .userInitiated)

    static var configRoot: URL {
        #if DEBUG
            if let configRootOverrideForTesting { return configRootOverrideForTesting }
        #endif
        return PiSetup.configRoot()
    }

    static var folderName: String { PathDisplay.abbreviatingHome(configRoot.path) }

    enum Startup: Equatable {
        case notInstalled
        case updated
        case updateFailed(PiSetupError)
        case edited(version: String)
        case current
    }

    static func refresh(
        applying change: Change? = nil, completion: @escaping (Result<PiSetup.State, PiSetupError>) -> Void
    ) {
        perform(completion: completion) { setup throws(PiSetupError) in
            switch change {
            case .install: _ = try setup.install()
            case .remove: _ = try setup.remove()
            case nil: break
            }
            return try setup.state()
        }
    }

    static func piStarted(completion: @escaping (Result<Startup, PiSetupError>) -> Void) {
        perform(completion: completion) { setup throws(PiSetupError) in
            switch try setup.state() {
            case .notInstalled: return .notInstalled
            case .edited: return .edited(version: setup.files.version)
            case .current, .newer: return .current
            case .outdated:
                do throws(PiSetupError) {
                    _ = try setup.install()
                    return .updated
                } catch {
                    return .updateFailed(error)
                }
            }
        }
    }

    private static func perform<Outcome>(
        completion: @escaping (Result<Outcome, PiSetupError>) -> Void,
        _ work: @escaping (PiSetup) throws(PiSetupError) -> Outcome
    ) {
        let configRoot = configRoot
        var files: PiSetupFiles?
        #if DEBUG
            files = filesOverrideForTesting
        #endif
        queue.async {
            let result = Result { () throws(PiSetupError) -> Outcome in
                guard let files = files ?? PiSetupFiles.bundled() else {
                    throw PiSetupError(message: "ZenTerm can't find the skill it ships with. Reinstall ZenTerm.")
                }
                return try work(PiSetup(configRoot: configRoot, files: files))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
