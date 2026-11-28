import ArgumentParser
import ControlProtocol

struct AwakeCommands: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "awake",
        abstract: "Hold the Mac awake for this pane, never the display.",
        discussion:
            "The hold ends on zen awake off, when its time runs out, when this pane exits, or when the person turns "
            + "Keep Awake off. Each prints what holds the Mac awake, as JSON.",
        subcommands: [Hold.self, Release.self, Status.self])

    struct Hold: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "on",
            abstract: "Hold the Mac awake until zen awake off or this pane exits. Again replaces the hold.")

        @OptionGroup var connection: ConnectionOptions

        @Option(name: .customLong("for"), help: "End the hold after this long, like 90s, 45m, 2h or 1h30m.")
        var duration: AwakeDuration?

        func run() throws {
            let args = ControlArgs(duration: duration?.seconds)
            print(try JSONOutput.text(connection.client().send(.awakeOn, args, expecting: AwakeResult.self)))
        }
    }

    struct Release: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "off", abstract: "End this pane's hold.")

        @OptionGroup var connection: ConnectionOptions

        func run() throws {
            print(try JSONOutput.text(connection.client().send(.awakeOff, expecting: AwakeResult.self)))
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print what holds the Mac awake.")

        @OptionGroup var connection: ConnectionOptions

        func run() throws {
            print(try JSONOutput.text(connection.client().send(.awakeStatus, expecting: AwakeResult.self)))
        }
    }
}

struct AwakeDuration: ExpressibleByArgument, Equatable {
    let seconds: Int

    init?(argument: String) {
        var total = 0
        var digits = ""
        var lastUnit = Int.max
        for character in argument {
            if character.isASCII, character.isNumber {
                digits.append(character)
                continue
            }
            let units: [Character: Int] = ["h": 60 * 60, "m": 60, "s": 1]
            guard let unit = units[character], unit < lastUnit, digits.count <= 6, let count = Int(digits) else {
                return nil
            }
            total += count * unit
            lastUnit = unit
            digits = ""
        }
        guard digits.isEmpty, total > 0 else { return nil }
        seconds = total
    }
}
