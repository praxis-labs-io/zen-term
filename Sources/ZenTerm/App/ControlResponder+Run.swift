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
        if let problem = Self.placementProblem(request.args) { return reply(.failure(problem)) }
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
            let float: Bool
            switch opensFloat(request, in: place) {
            case .failure(let error): return .failure(error)
            case .success(let opens): float = opens
            }
            if float {
                let start = startFolder(of: place, for: request)
                let cwd = request.args.cwd != nil ? start : place.window.outsideRemovedWorktree(start, in: workspace)
                return openFloat(beside: place, running: program, cwd: cwd, focus: focus).map { (place.window, $0) }
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

    private static func placementProblem(_ args: ControlArgs) -> ControlError? {
        guard let float = args.float else { return nil }
        if args.split != nil {
            return ControlError(.badRequest, "pane.run takes a split or \(float ? "a float" : "a tab"), not both.")
        }
        if float, args.outliveParent == true {
            return ControlError(
                .badRequest, "A float closes with its tab, so a pane that outlives its parent opens a tab.")
        }
        return nil
    }

    // A float is opened from its agent's row in the Agents list, which lists only its own window's panes,
    // and closes when that agent exits.
    private func opensFloat(_ request: ControlRequest, in place: PanePlace) -> Result<Bool, ControlError> {
        let caller = request.caller?.pane.flatMap(locate(pane:))
        let acrossWindows = caller.map { $0.window !== place.window } ?? false
        switch request.args.float {
        case false?: return .success(false)
        case true?:
            guard let caller, caller.window.hasAgent(atOrAbove: caller.pane.token) else {
                return .failure(
                    ControlError(
                        .refused,
                        "A float opens only from an agent's pane, or a pane an agent started, so the Agents list "
                            + "can show it."))
            }
            if acrossWindows {
                return .failure(
                    ControlError(
                        .refused,
                        "Pane \(place.pane.token) is in another window, and a float opens only in its agent's "
                            + "window. Leave out --float to open a tab there."))
            }
            return .success(true)
        case nil:
            let onHost = place.window.workspaceID(of: place.tab).flatMap(place.window.host(of:)) != nil
            let fromAgent = caller.map { $0.window.runsAgent($0.pane.surfaceID) } ?? false
            return .success(fromAgent && request.args.outliveParent != true && !onHost && !acrossWindows)
        }
    }

    private func openFloat(beside place: PanePlace, running program: PaneProgram, cwd: URL?, focus: Bool)
        -> Result<Int, ControlError>
    {
        if let host = place.window.workspaceID(of: place.tab).flatMap(place.window.host(of:)) {
            return .failure(
                ControlError(
                    .refused,
                    "Pane \(place.pane.token) is on \(ControlAddress.hostPrefix + host.alias), and a float there "
                        + "takes no cmd."))
        }
        guard let token = place.window.openFloatPane(in: place.tab, running: program, cwd: cwd) else {
            return .failure(ControlError(.notFound, "That tab is gone."))
        }
        if focus, let opened = place.window.pane(token: token) {
            place.window.focus(opened.pane.surfaceID, in: opened.tab)
            raise(place.window)
        }
        return .success(token)
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
                token: pane.token, drawer: pane.drawer, float: pane.float, title: pane.title, cwd: pane.cwd,
                busy: pane.busy, process: pane.process, agent: pane.agent, name: pane.name, parent: pane.parent,
                firstTask: firstTask ?? pane.firstTask))
    }
}
