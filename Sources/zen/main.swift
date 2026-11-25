import Foundation

let arguments = CommandLine.arguments
let environment = ProcessInfo.processInfo.environment
if Askpass.runs(arguments: arguments, environment: environment) {
    exit(Askpass.exitCode(prompt: arguments[1], environment: environment))
}
exit(Zen.exitCode(running: Array(arguments.dropFirst())))
