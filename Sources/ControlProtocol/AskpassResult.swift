/// The answer `ssh.askpass` hands back for ssh to read.
public struct AskpassResult: ControlPayload, Equatable {
    public let answer: AskpassAnswer

    public init(answer: AskpassAnswer) { self.answer = answer }
}
