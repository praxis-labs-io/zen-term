import ControlProtocol
import Foundation
import PaneKit
import TabKit
import TerminalKit

struct PanePlace {
    let window: WindowController
    let tab: TabID
    let pane: PaneHandle
}

extension ControlResponder {
    func pane(_ address: ControlAddress.Pane?, for request: ControlRequest) -> Result<PanePlace, ControlError> {
        switch address {
        case .token(let token):
            guard let found = locate(pane: token) else {
                return .failure(ControlError(.notFound, "There is no pane \(token)."))
            }
            return .success(PanePlace(window: found.window, tab: found.tab, pane: found.pane))
        case .name(let name):
            let found = locate(paneNamed: name)
            guard found.count < 2 else {
                return .failure(ControlError(.ambiguous, "\(found.count) panes are named \(name)."))
            }
            guard let only = found.first else {
                return .failure(ControlError(.notFound, "There is no pane named \(name)."))
            }
            return .success(PanePlace(window: only.window, tab: only.tab, pane: only.pane))
        case nil: break
        }
        return caller(request).flatMap { context in
            guard let tab = context.tab, let pane = context.pane ?? context.window.focusedPane(of: tab) else {
                return .failure(ControlError(.notFound, "No pane is open."))
            }
            return .success(PanePlace(window: context.window, tab: tab, pane: pane))
        }
    }

    func splitPane(_ request: ControlRequest) -> ControlReply {
        guard let direction = request.args.dir else {
            return .failure(ControlError(.badRequest, "pane.split needs a dir, right or down."))
        }
        return pane(request.args.pane, for: request).flatMap { place in
            let command = request.args.cmd.flatMap { $0.isEmpty ? nil : PaneProgram(command: $0) }
            return split(place, direction, running: command, focus: request.args.focus == true)
                .map { PaneResult(pane: $0) as any ControlPayload }
        }
    }

    func split(_ place: PanePlace, _ direction: PaneDirection, running command: PaneProgram?, focus: Bool)
        -> Result<Int, ControlError>
    {
        let token = place.pane.token
        if place.pane.drawer != nil {
            return .failure(ControlError(.badRequest, "Pane \(token) is a drawer, and a drawer does not split."))
        }
        if command != nil, let host = place.window.workspaceID(of: place.tab).flatMap(place.window.host(of:)) {
            return .failure(
                ControlError(
                    .refused,
                    "Pane \(token) is on \(ControlAddress.hostPrefix + host.alias), and a split there takes no cmd. "
                        + "It starts the host's login shell."))
        }
        switch place.window.splitPane(token, in: place.tab, axis: Self.axis(direction), command: command) {
        case nil:
            return .failure(ControlError(.notFound, "There is no pane \(token)."))
        case .focusMode:
            return .failure(ControlError(.refused, "Pane \(token)'s tab is in Focus Mode. Exit Focus Mode to split."))
        case .tooSmall:
            return .failure(ControlError(.failed, "Pane \(token) is too small to split."))
        case .opened(let opened):
            if focus, let new = place.window.pane(token: opened) {
                place.window.focus(new.pane.surfaceID, in: new.tab)
                raise(place.window)
            }
            return .success(opened)
        }
    }

    private static func axis(_ direction: PaneDirection) -> SplitAxis {
        switch direction {
        case .right: return .vertical
        case .down: return .horizontal
        }
    }

    func focusPane(_ request: ControlRequest) -> ControlReply {
        pane(request.args.pane, for: request).map { place in
            place.window.focus(place.pane.surfaceID, in: place.tab)
            raise(place.window)
            return NoPayload()
        }
    }

    func closePane(_ request: ControlRequest) -> ControlReply {
        pane(request.args.pane, for: request).flatMap { place in
            let token = place.pane.token
            if place.pane.drawer != nil {
                return .failure(ControlError(.badRequest, "Pane \(token) is a drawer, which pane.close leaves open."))
            }
            guard let stakes = place.window.closeStakes(pane: place.pane, in: place.tab) else {
                return .failure(ControlError(.notFound, "There is no pane \(token)."))
            }
            if stakes.needsForce, request.args.force != true {
                return .failure(Self.refusal(closing: "pane \(token)", stakes))
            }
            if stakes.login != nil { return Self.abandonLogin(holding: place.tab, in: place.window) }
            place.window.removePane(token, in: place.tab)
            return .success(NoPayload())
        }
    }

    func sendToPane(_ request: ControlRequest) -> ControlReply {
        guard let text = request.args.text else {
            return .failure(ControlError(.badRequest, "pane.send needs text."))
        }
        return pane(request.args.pane, for: request).flatMap { place in
            let surface = place.pane.surface
            guard surface.isStarted else { return .failure(Self.notStarted(place.pane.token)) }
            if !text.isEmpty { surface.paste(text) }
            if request.args.enter == true { surface.submit() }
            paneWaits.sent(to: place.pane.surfaceID)
            return .success(NoPayload())
        }
    }

    func pressKeys(_ request: ControlRequest) -> ControlReply {
        guard let names = request.args.keys, !names.isEmpty else {
            return .failure(ControlError(.badRequest, "pane.keys needs keys."))
        }
        var keys: [PaneKey] = []
        for name in names {
            guard let key = PaneKey(name: name) else {
                let known = PaneKey.names.joined(separator: ", ")
                return .failure(ControlError(.badRequest, "There is no key named \(name). The keys are \(known)."))
            }
            keys.append(key)
        }
        return pane(request.args.pane, for: request).flatMap { place in
            let surface = place.pane.surface
            guard surface.isStarted else { return .failure(Self.notStarted(place.pane.token)) }
            var pressed: [TerminalKey] = []
            for key in keys {
                guard let typed = TerminalKey(paneKey: key) else {
                    return .failure(ControlError(.failed, "The keyboard layout has no key for \(key.name)."))
                }
                pressed.append(typed)
            }
            pressed.forEach(surface.press)
            return .success(NoPayload())
        }
    }

    // A remote host's foreground is the local ssh, which a signal would end; its remote terminal turns Ctrl-C into one.
    func interruptPane(_ request: ControlRequest) -> ControlReply {
        pane(request.args.pane, for: request).flatMap { place in
            let surface = place.pane.surface
            let token = place.pane.token
            guard surface.isStarted else { return .failure(Self.notStarted(token)) }
            if place.window.runsAgent(place.pane) {
                surface.press(.escape)
                return .success(NoPayload())
            }
            if place.window.workspaceID(of: place.tab).flatMap(place.window.host(of:)) != nil {
                guard let controlC = TerminalKey(paneKey: .control("c")) else {
                    return .failure(ControlError(.failed, "The keyboard layout has no key for ctrl-c."))
                }
                surface.press(controlC)
                return .success(NoPayload())
            }
            guard let group = surface.foregroundProcessGroupID, interruptGroup(group) else {
                return .failure(ControlError(.failed, "Pane \(token)'s foreground process could not be interrupted."))
            }
            return .success(NoPayload())
        }
    }

    static func interrupt(group: pid_t) -> Bool { killpg(group, SIGINT) == 0 }

    func readPane(_ request: ControlRequest) -> ControlReply {
        if let lines = request.args.lines, lines < 1 {
            return .failure(ControlError(.badRequest, "lines must be 1 or more."))
        }
        return pane(request.args.pane, for: request).flatMap { place in
            let surface = place.pane.surface
            guard surface.isStarted else { return .failure(Self.notStarted(place.pane.token)) }
            let text: String?
            if let lines = request.args.lines {
                text = surface.text(lastLines: lines)
            } else {
                text = Self.viewport(of: surface)
            }
            guard let text else {
                return .failure(ControlError(.failed, "Pane \(place.pane.token) could not be read."))
            }
            return .success(PaneText(text: text))
        }
    }

    func getPane(_ request: ControlRequest) -> ControlReply {
        pane(request.args.pane, for: request).map { place in place.window.listing(of: place.pane, in: place.tab) }
    }

    func waitOnPane(_ request: ControlRequest, hangup: ControlHangup, reply: @escaping (ControlReply) -> Void) {
        let timeout = request.args.timeout ?? ControlWire.defaultPaneWait
        guard (1...ControlWire.longestPaneWait).contains(timeout) else {
            return reply(
                .failure(ControlError(.badRequest, "timeout must be 1 to \(ControlWire.longestPaneWait) seconds.")))
        }
        if request.args.output?.isEmpty == true {
            return reply(.failure(ControlError(.badRequest, "output must not be empty.")))
        }
        if request.args.output?.contains(where: \.isNewline) == true {
            return reply(.failure(ControlError(.badRequest, "output matches within one line, so it takes no newline.")))
        }
        if let children = request.args.children {
            guard request.args.pane == nil else {
                return reply(.failure(ControlError(.badRequest, "pane.wait takes a pane or children, not both.")))
            }
            if children == .all, request.args.output != nil {
                return reply(.failure(ControlError(.badRequest, "output takes a pane or children any.")))
            }
            return waitOnChildren(children, request, timeout: timeout, hangup: hangup, reply: reply)
        }
        guard let address = request.args.pane else {
            return reply(.failure(ControlError(.badRequest, "pane.wait needs a pane or children.")))
        }
        switch pane(address, for: request) {
        case .failure(let error):
            if error.code == .notFound, case .token(let token) = address, let exit = launchedExit(of: token) {
                return reply(
                    .success(
                        WaitResult(
                            reason: .exited, exitCode: exit.exitCode, text: exit.lastLines,
                            pane: exit.pane ?? Self.closedPane(exit))))
            }
            reply(.failure(error))
        case .success(let place):
            let caller = request.caller?.pane.flatMap { locate(pane: $0)?.pane.surfaceID }
            let answered: (PaneWait.Answer) -> Void = {
                reply(.success(WaitResult(reason: $0.reason, exitCode: $0.exitCode, text: $0.text, pane: $0.pane)))
            }
            guard let wait = PaneWait(watched(place), caller: caller, output: request.args.output, reply: answered)
            else {
                return reply(.failure(ControlError(.notFound, "There is no pane \(place.pane.token).")))
            }
            paneWaits.hold(wait, timeout: TimeInterval(timeout), hangup: hangup)
        }
    }

    private func waitOnChildren(
        _ mode: WaitChildren, _ request: ControlRequest, timeout: Int, hangup: ControlHangup,
        reply: @escaping (ControlReply) -> Void
    ) {
        guard let parent = request.caller?.pane else {
            return reply(.failure(ControlError(.badRequest, "pane.wait waits on children from a pane.")))
        }
        guard let caller = locate(pane: parent) else {
            return reply(.failure(ControlError(.notFound, "There is no pane \(parent).")))
        }
        let children = windows().flatMap { window in
            window.panes(childOf: parent).map { found in
                let token = found.pane.token
                return ChildrenWait.Child(
                    token: token, watched: watched(PanePlace(window: window, tab: found.tab, pane: found.pane)),
                    isWorking: { [self] in
                        locate(pane: token).map { $0.window.isWorking(helper: $0.pane, in: $0.tab) } ?? false
                    })
            }
        }
        guard !children.isEmpty else { return reply(.success(WaitResult(reason: .noChildren, children: []))) }
        let wait = ChildrenWait(
            children, mode: mode, caller: caller.pane.surfaceID, output: request.args.output, reply: reply)
        paneWaits.hold(wait, timeout: TimeInterval(timeout), hangup: hangup)
    }

    private func watched(_ place: PanePlace) -> PaneWait.Watched {
        let token = place.pane.token
        let onHost = place.window.workspaceID(of: place.tab).flatMap(place.window.host(of:)) != nil
        return PaneWait.Watched(
            surfaceID: place.pane.surfaceID, surface: place.pane.surface, readsForeground: !onHost,
            pane: { [self] in locate(pane: token).map { $0.window.listing(of: $0.pane, in: $0.tab) } },
            exit: { [self] in launchedExit(of: token) })
    }

    private func launchedExit(of token: Int) -> LaunchedPaneExit? {
        windows().lazy.compactMap { $0.launchedPaneExits.exit(of: token) }.first
    }

    private static func closedPane(_ exit: LaunchedPaneExit) -> ListResult.Pane {
        ListResult.Pane(
            token: exit.token, drawer: nil, title: "", cwd: nil, busy: false, agent: nil, name: exit.record.name,
            parent: exit.record.parent, firstTask: exit.record.firstTask)
    }

    private static func notStarted(_ token: Int) -> ControlError {
        ControlError(.failed, "Pane \(token) has not started.")
    }

    private static func viewport(of surface: TerminalSurface) -> String? {
        guard let rows = surface.cellMetrics?.rows else { return nil }
        var lines = (0..<rows).map { surface.text(viewportRow: $0) ?? "" }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
