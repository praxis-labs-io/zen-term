import ControlProtocol
import Foundation

extension ControlResponder {
    func runInPane(_ request: ControlRequest, reply: @escaping (ControlReply) -> Void) {
        guard let command = request.args.cmd, !command.isEmpty else {
            return reply(.failure(ControlError(.badRequest, "pane.run needs a cmd to run.")))
        }
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
                return split(place, direction, running: program, focus: focus).map { (place.window, $0) }
            }
            guard let workspace = place.window.workspaceID(of: place.tab) else {
                return .failure(ControlError(.notFound, "That workspace is gone."))
            }
            return openTab(
                in: WorkspacePlace(window: place.window, id: workspace), cwd: place.pane.cwd, explicitCWD: false,
                running: program, focus: focus
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
                return reply(.success(PaneRunResult(pane: token, firstTask: nil)))
            }
            window.deliverFirstTask(task, toPane: token) { outcome in
                reply(.success(PaneRunResult(pane: token, firstTask: outcome)))
            }
        }
    }
}
