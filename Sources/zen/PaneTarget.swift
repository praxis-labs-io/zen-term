import ArgumentParser
import ControlProtocol

struct PaneTarget: ParsableArguments {
    static let namedTwice = ValidationError("Name the pane as an argument or with --pane, not both.")
    static let unnamed = ValidationError("Name a pane, as an argument or with --pane.")
    static let thisPaneByDefault = "Without a pane, it acts on this one."

    @Argument(help: ArgumentHelp("A pane or drawer token, or a pane's name.", valueName: "pane"))
    var positional: ControlAddress.Pane?

    @Option(name: .customLong("pane"), help: "The pane, as an option instead of an argument.")
    var option: ControlAddress.Pane?

    var pane: ControlAddress.Pane? { positional ?? option }

    func validate() throws {
        if positional != nil, option != nil { throw Self.namedTwice }
    }

    func required() throws -> ControlAddress.Pane {
        guard let pane else { throw Self.unnamed }
        return pane
    }
}
