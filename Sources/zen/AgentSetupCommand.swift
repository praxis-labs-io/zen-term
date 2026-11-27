import AgentSetup
import ArgumentParser
import Foundation

// The shape of `zen setup <agent> [--remove]`: install or remove, then print one line per change.
protocol AgentSetupCommand: ParsableCommand {
    associatedtype Installer: AgentInstaller

    static var agentName: String { get }
    var remove: Bool { get }
}

extension AgentSetupCommand {
    func run() throws {
        let lines = try changes(
            environment: ProcessInfo.processInfo.environment,
            files: Installer.Files.bundled(beside: Bundle.main.executableURL))
        lines.forEach { print($0) }
    }

    func changes(environment: [String: String], files: Installer.Files?) throws(ZenFailure) -> [String] {
        guard let files else {
            throw .app(
                "zen can't find the skill it ships with. Run the zen inside ZenTerm, at "
                    + "ZenTerm.app/Contents/MacOS/zen.")
        }
        let setup = Installer(configRoot: Installer.configRoot(environment: environment), files: files)
        do {
            if remove {
                let removed = try setup.remove()
                return removed.isEmpty ? ["Nothing to remove: zen isn't set up for \(Self.agentName)."] : removed
            }
            let changed = try setup.install()
            return changed.isEmpty ? ["Nothing to change: zen is set up for \(Self.agentName)."] : changed
        } catch {
            throw .app(error.message)
        }
    }
}
