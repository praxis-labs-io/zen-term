import ControlProtocol

// A wait prints its answer whatever it was, and its exit code says whether the thing waited on went as hoped.
enum WaitAnswer {
    static func print(_ result: WaitResult) throws {
        Swift.print(try JSONOutput.text(result))
        let code = exitCode(for: result)
        if code != 0 { throw ZenFailure.answered(code) }
    }

    static func exitCode(for result: WaitResult) -> Int32 {
        switch result.reason {
        case .timeout: return ZenFailure.timeoutCode
        case .message: return ZenFailure.messageCode
        case .stopped, .exited, .output, .noChildren:
            let exits = result.children?.map { ($0.reason, $0.exitCode) } ?? [(result.reason, result.exitCode)]
            return exits.contains(where: failed) ? ZenFailure.programFailedCode : 0
        }
    }

    private static func failed(_ reason: WaitReason?, _ exitCode: Int?) -> Bool {
        reason == .exited && exitCode != 0
    }
}
