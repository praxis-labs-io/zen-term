import ControlProtocol
import Foundation

// `zen` as a host login's SSH_ASKPASS: ssh runs it with its question as the one argument and reads the answer from stdout.
enum Askpass {
    static let hintKey = "SSH_ASKPASS_PROMPT"

    static func runs(arguments: [String], environment: [String: String]) -> Bool {
        arguments.count == 2 && environment[ControlEndpoint.askpassTokenKey]?.isEmpty == false
    }

    // `confirm` is a yes/no ssh reads a failure as no to; `none` is a notice that needs no answer.
    static func exitCode(
        prompt: String, environment: [String: String], sshPID: pid_t = getppid(),
        answer: (String) -> Void = { print($0) }, fail: (String) -> Void = Askpass.printError
    ) -> Int32 {
        switch environment[hintKey] {
        case "confirm": return ZenFailure.appErrorCode
        case "none": return 0
        default: break
        }
        guard let token = environment[ControlEndpoint.askpassTokenKey],
            let path = environment[ControlEndpoint.environmentKey], !path.isEmpty
        else {
            fail("zen: this ssh was not started by ZenTerm, so there is nobody to ask.")
            return ZenFailure.noInstanceCode
        }
        let args = ControlArgs(token: token, prompt: prompt, sshPID: Int(sshPID))
        let client = ControlClient(
            path: path, caller: nil, replyTimeout: ControlClient.replyTimeout(for: .sshAskpass, args))
        do {
            answer(try client.send(.sshAskpass, args, expecting: AskpassResult.self).answer.text)
            return 0
        } catch {
            fail("zen: \(error.message)")
            return error.exitCode
        }
    }

    static func printError(_ text: String) {
        var standardError = StandardError()
        print(text, to: &standardError)
    }
}
