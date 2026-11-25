import ControlProtocol

extension ControlResponder {
    // The token, never `caller.pane`, picks the login: any process of this user can claim a pane.
    func askLogin(_ request: ControlRequest, hangup: ControlHangup, reply: @escaping (ControlReply) -> Void) {
        guard let token = request.args.token, let prompt = request.args.prompt else {
            return reply(.failure(ControlError(.badRequest, "ssh.askpass needs a token and a prompt.")))
        }
        let answer: SSHConnection.AskpassReply = { reply($0.map { AskpassResult(answer: $0) }) }
        let asked = windows().contains {
            $0.askLogin(prompt, sshPID: request.args.sshPID, token: token, hangup: hangup, reply: answer)
        }
        if !asked { reply(.failure(ControlError(.notFound, "No ssh login is waiting for an answer."))) }
    }
}
