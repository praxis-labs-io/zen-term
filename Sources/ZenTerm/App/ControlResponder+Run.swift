import ControlProtocol
import Foundation

extension ControlResponder {
    func runInPane(_ request: ControlRequest, hangup: ControlHangup, reply: @escaping (ControlReply) -> Void) {
        guard let command = request.args.cmd, !command.isEmpty else {
            return reply(.failure(ControlError(.badRequest, "pane.run needs a cmd to run.")))
        }
        if request.args.wait == true, case .failure(let error) = Self.waitTimeout(request) {
            return reply(.failure(error))
        }
        if request.args.output != nil, request.args.wait != true {
            return reply(.failure(ControlError(.badRequest, "output needs wait.")))
        }
        if let problem = Self.outputProblem(request.args.output) { return reply(.failure(problem)) }
        if let problem = Self.cwdProblem(request.args) { return reply(.failure(problem)) }
        let name = request.args.name
        if let name {
            guard ControlAddress.Pane.isValidName(name) else {
                return reply(
                    .failure(
                        ControlError(.badRequest, "A pane name needs a character that is not a digit or a space.")))
            }
            if let open = locate(paneNamed: name).first {
                return reply(
                    .failure(ControlError(.refused, "Pane \(open.pane.token) is already named \(name).")))
            }
        }
        let program = PaneProgram(command: command, exitClosesPane: request.args.keep != true, marksExit: true)
        let focus = request.args.focus == true
        let opened = pane(request.args.pane, for: request).flatMap {
            place -> Result<(WindowController, Int), ControlError> in
            if let direction = request.args.split {
                let cwd = callerFolder(as: place.pane.token, for: request)
                return split(place, direction, running: program, cwd: cwd, focus: focus).map { (place.window, $0) }
            }
            guard let workspace = place.window.workspaceID(of: place.tab) else {
                return .failure(ControlError(.notFound, "That workspace is gone."))
            }
            return openTab(
                in: WorkspacePlace(window: place.window, id: workspace), cwd: startFolder(of: place, for: request),
                explicitCWD: request.args.cwd != nil, running: program, focus: focus
            ).map { (place.window, $0.pane) }
        }
        switch opened {
        case .failure(let error):
            reply(.failure(error))
        case .success(let (window, token)):
            window.updateRecord(pane: token) {
                $0.name = name
                $0.parent = request.caller?.pane
                $0.outlivesParent = request.args.outliveParent == true
            }
            guard let task = request.args.task, !task.isEmpty else {
                return answer(PaneRunResult(pane: token, firstTask: nil), for: request, hangup: hangup, reply: reply)
            }
            window.deliverFirstTask(task, toPane: token) { [self] outcome in
                answer(PaneRunResult(pane: token, firstTask: outcome), for: request, hangup: hangup, reply: reply)
            }
        }
    }

    private static func cwdProblem(_ args: ControlArgs) -> ControlError? {
        guard let cwd = args.cwd else { return nil }
        if args.split != nil { return ControlError(.badRequest, "pane.run takes a cwd or a split, not both.") }
        return cwd.hasPrefix("/") ? nil : ControlError(.badRequest, "\(cwd) is not an absolute path.")
    }

    private func startFolder(of place: PanePlace, for request: ControlRequest) -> URL? {
        if let cwd = request.args.cwd { return URL(fileURLWithPath: cwd, isDirectory: true) }
        return callerFolder(as: place.pane.token, for: request) ?? place.pane.cwd
    }

    // The wait's answer carries the pane as `pane.get` reports it, its `first_task` included.
    private func answer(
        _ ran: PaneRunResult, for request: ControlRequest, hangup: ControlHangup,
        reply: @escaping (ControlReply) -> Void
    ) {
        guard request.args.wait == true, case .success(let timeout) = Self.waitTimeout(request) else {
            return reply(.success(ran))
        }
        guard let found = locate(pane: ran.pane) else {
            guard let exit = launchedExit(of: ran.pane) else {
                return reply(.failure(ControlError(.notFound, "Pane \(ran.pane) closed before the wait began.")))
            }
            return reply(.success(Self.exited(exit, firstTask: ran.firstTask)))
        }
        let place = PanePlace(window: found.window, tab: found.tab, pane: found.pane)
        hold(waitOn: place, output: request.args.output, timeout: timeout, for: request, hangup: hangup, reply: reply)
    }

    // The exit was kept before the first task settled, so its pane does not carry that answer yet.
    private static func exited(_ exit: LaunchedPaneExit, firstTask: FirstTask?) -> WaitResult {
        let answer = exited(exit)
        guard let pane = answer.pane else { return answer }
        return WaitResult(
            reason: .exited, exitCode: answer.exitCode, text: answer.text,
            pane: ListResult.Pane(
                token: pane.token, drawer: pane.drawer, title: pane.title, cwd: pane.cwd, busy: pane.busy,
                process: pane.process, agent: pane.agent, name: pane.name, parent: pane.parent,
                firstTask: firstTask ?? pane.firstTask))
    }
}
