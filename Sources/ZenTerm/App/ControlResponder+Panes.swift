import AppLog
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
            if let parent = request.caller?.pane {
                if let own = locate(paneNamed: name, startedBy: parent) {
                    return .success(PanePlace(window: own.window, tab: own.tab, pane: own.pane))
                }
                if let exit = latestExit(named: name, startedBy: parent) {
                    return .failure(ControlError(.notFound, "Pane \(exit.token), named \(name), exited."))
                }
            }
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
            return split(
                place, direction, running: command, cwd: callerFolder(as: place.pane.token, for: request),
                focus: request.args.focus == true
            )
            .map { PaneResult(pane: $0) as any ControlPayload }
        }
    }

    func split(
        _ place: PanePlace, _ direction: PaneDirection, running command: PaneProgram?, cwd: URL?, focus: Bool
    ) -> Result<Int, ControlError> {
        let token = place.pane.token
        switch place.pane.location {
        case .drawer:
            return .failure(ControlError(.badRequest, "Pane \(token) is a drawer, and a drawer does not split."))
        case .float:
            return .failure(ControlError(.badRequest, "Pane \(token) is a float, and a float does not split."))
        case .tree: break
        }
        if command != nil, let host = place.window.workspaceID(of: place.tab).flatMap(place.window.host(of:)) {
            return .failure(
                ControlError(
                    .refused,
                    "Pane \(token) is on \(ControlAddress.hostPrefix + host.alias), and a split there takes no cmd. "
                        + "It starts the host's login shell."))
        }
        switch place.window.splitPane(token, in: place.tab, axis: Self.axis(direction), command: command, cwd: cwd) {
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
            let byParent = request.caller?.pane.map { $0 == place.pane.record.parent } ?? false
            guard let stakes = place.window.closeStakes(pane: place.pane, in: place.tab, closedByItsParent: byParent)
            else {
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

    func sendToPane(_ request: ControlRequest, hangup: ControlHangup, reply: @escaping (ControlReply) -> Void) {
        guard let text = request.args.text else {
            return reply(.failure(ControlError(.badRequest, "pane.send needs text.")))
        }
        if ZenEnvelope.carriesTag(text) {
            let tagged = "pane.send text cannot contain a <zen or </zen tag, which marks who sent a message."
            return reply(.failure(ControlError(.badRequest, tagged)))
        }
        if request.args.wait == true, case .failure(let error) = Self.waitTimeout(request) {
            return reply(.failure(error))
        }
        switch pane(request.args.pane, for: request) {
        case .failure(let error): reply(.failure(error))
        case .success(let place):
            let fromHelper = isHelper(request.caller?.pane, of: place)
            if !fromHelper,
                let refusal = Self.refusal(.paste, into: place, from: request.caller?.pane, force: request.args.force)
            {
                return reply(.failure(refusal))
            }
            let token = place.pane.token
            let isHeld =
                paneDrafts.isHolding(place.pane.surfaceID)
                || Self.refusal(.paste, into: place, from: request.caller?.pane, force: request.args.force) != nil
            guard place.window.runsAgent(place.pane), isHeld else {
                return answer(deliver(to: token, for: request), for: request, hangup: hangup, reply: reply)
            }
            if fromHelper, request.args.enter == true, !text.isEmpty {
                noteDelivery(from: request.caller?.pane, to: place, submitted: true)
            }
            let isBlocked = { [self] in
                guard case .success(let place) = pane(.token(token), for: request) else { return false }
                return Self.refusal(.paste, into: place, from: request.caller?.pane, force: request.args.force) != nil
            }
            var wait: PaneWait?
            if request.args.wait == true, case .success(let timeout) = Self.waitTimeout(request) {
                wait = hold(waitOn: place, output: nil, timeout: timeout, for: request, hangup: hangup, reply: reply)
            } else {
                reply(.success(PaneSendResult(queued: true)))
            }
            let drop = { (reason: String) in
                Log.warning("Dropped a pane.send queued for pane \(token): \(reason).", category: .control)
                wait?.cancel()
                reply(.failure(ControlError(.failed, "The send queued for pane \(token) was dropped: \(reason).")))
            }
            let setsDraftAside = { [self] in
                guard request.args.enter == true, let text = request.args.text, Self.startsTurn(text),
                    case .success(let place) = pane(.token(token), for: request)
                else {
                    return false
                }
                return place.window.draftStash(of: place.pane) != nil
            }
            paneDrafts.queue(
                place.pane.surfaceID,
                PaneDrafts.Message(
                    isTask: request.args.enter == true && Self.startsTurn(request.args.text ?? ""),
                    setsDraftAside: setsDraftAside,
                    isBlocked: isBlocked,
                    deliver: { [self] overDraft in
                        if case .failure(let error) = deliver(to: token, for: request, overDraft: overDraft) {
                            drop(error.message)
                        }
                    },
                    drop: drop, waitsOutAnyBlock: fromHelper))
        }
    }

    private func isHelper(_ sender: Int?, of place: PanePlace) -> Bool {
        guard let sender, let helper = locate(pane: sender) else { return false }
        return helper.pane.record.parent == place.pane.token
    }

    // The pane is found again because a queued message can outlast it, and its agent can block meanwhile.
    private func deliver(
        to token: Int, for request: ControlRequest, overDraft: Bool = false
    ) -> Result<PanePlace, ControlError> {
        let found = pane(.token(token), for: request).flatMap { place -> Result<PanePlace, ControlError> in
            guard place.pane.surface.isStarted else { return .failure(Self.notStarted(token)) }
            if let refusal = Self.refusal(.paste, into: place, from: request.caller?.pane, force: request.args.force) {
                return .failure(refusal)
            }
            return .success(place)
        }
        guard case .success(let place) = found else { return found }
        let text = request.args.text ?? ""
        let enter = request.args.enter == true
        paste(text, from: request.caller?.pane, into: place, enter: enter, overDraft: overDraft)
        noteDelivery(from: request.caller?.pane, to: place, submitted: enter && !text.isEmpty)
        if enter, Self.startsTurn(text) { place.window.noteTaskSubmitted(to: place.pane) }
        return found
    }

    private func answer(
        _ delivered: Result<PanePlace, ControlError>, for request: ControlRequest, hangup: ControlHangup,
        reply: @escaping (ControlReply) -> Void
    ) {
        guard case .success(let place) = delivered else { return reply(delivered.map { _ in NoPayload() }) }
        guard request.args.wait == true, case .success(let timeout) = Self.waitTimeout(request) else {
            return reply(.success(NoPayload()))
        }
        hold(waitOn: place, output: nil, timeout: timeout, for: request, hangup: hangup, reply: reply)
    }

    // A helper's message to its parent already carries the news its `stopped` note would, until the parent answers.
    // Only a submitted message is a helper's report; a parent's keys or paste can still answer its helper.
    private func noteDelivery(from sender: Int?, to place: PanePlace, submitted: Bool) {
        guard let sender else { return }
        if place.pane.record.parent == sender { return place.window.helperHeardFromParent(place.pane.surfaceID) }
        guard submitted, let helper = locate(pane: sender), helper.pane.record.parent == place.pane.token else {
            return
        }
        helper.window.helperReported(helper.pane.surfaceID)
    }

    enum Delivery {
        case paste, keys

        fileprivate var verbs: (done: String, to: String) {
            switch self {
            case .paste: return ("sent", "send")
            case .keys: return ("pressed", "press")
            }
        }
    }

    // Input would answer the prompt, which is the user's, except a helper's question about the task its parent set.
    static func refusal(_ delivery: Delivery, into place: PanePlace, from sender: Int?, force: Bool?) -> ControlError? {
        guard force != true, let agent = place.window.listing(of: place.pane, in: place.tab).agent,
            agent.status == .blocked
        else { return nil }
        if agent.kind == .question, let sender, sender == place.pane.record.parent { return nil }
        let waitsOn = agent.kind.map { " for \($0.rawValue)" } ?? ""
        return ControlError(
            .refused,
            "Pane \(place.pane.token)'s agent is waiting on the user\(waitsOn), and that decision is the user's. "
                + "Nothing was \(delivery.verbs.done). Pass --force to \(delivery.verbs.to) anyway.")
    }

    func paste(_ text: String, from sender: Int?, into place: PanePlace, enter: Bool, overDraft: Bool = false) {
        let surface = place.pane.surface
        if enter { place.window.markTask(on: place.pane) }
        if overDraft, let stash = place.window.draftStash(of: place.pane) { surface.press(stash) }
        if !text.isEmpty { pastes(text, from: sender, into: place).forEach(surface.paste) }
        if enter { surface.submit() }
        paneWaits.sent(to: place.pane.surfaceID)
    }

    func pastes(_ text: String, from sender: Int?, into place: PanePlace) -> [String] {
        guard place.window.runsAgent(place.pane) else { return [text] }
        return AgentPaste.pieces(
            of: envelope(text, from: sender, into: place), rows: place.pane.surface.cellMetrics?.rows)
    }

    // An agent reads a bare paste as its user typing, so another agent's message says who sent it and how to answer.
    private func envelope(_ text: String, from sender: Int?, into place: PanePlace) -> String {
        guard let sender, sender != place.pane.token, place.window.runsAgent(place.pane), !Self.isSlashCommand(text)
        else { return text }
        return ZenEnvelope.wrap(text, from: sender, named: locate(pane: sender)?.pane.record.name)
    }

    private static func startsTurn(_ text: String) -> Bool { !text.isEmpty && !isSlashCommand(text) }

    // A wrapped slash command reaches the agent as a message and never runs.
    private static func isSlashCommand(_ text: String) -> Bool {
        text.hasPrefix("/") && !text.contains(where: \.isNewline)
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
            if let refusal = Self.refusal(.keys, into: place, from: request.caller?.pane, force: request.args.force) {
                return .failure(refusal)
            }
            var pressed: [TerminalKey] = []
            for key in keys {
                guard let typed = TerminalKey(paneKey: key) else {
                    return .failure(ControlError(.failed, "The keyboard layout has no key for \(key.name)."))
                }
                pressed.append(typed)
            }
            pressed.forEach(surface.press)
            noteDelivery(from: request.caller?.pane, to: place, submitted: false)
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
        if request.args.lines != nil, request.args.since != nil {
            return .failure(ControlError(.badRequest, "pane.read takes lines or since, not both."))
        }
        return pane(request.args.pane, for: request).flatMap { place in
            let surface = place.pane.surface
            guard surface.isStarted else { return .failure(Self.notStarted(place.pane.token)) }
            if request.args.since == .task { return Self.sinceTask(place) }
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

    private static func sinceTask(_ place: PanePlace) -> ControlReply {
        switch place.window.readSinceTask(of: place.pane) {
        case .noTask:
            return .failure(
                ControlError(.failed, "Pane \(place.pane.token) has had no task or message sent with enter."))
        case .unreadable:
            return .failure(ControlError(.failed, "Pane \(place.pane.token) could not be read."))
        case .text(let text, let truncated):
            return .success(PaneText(text: text, truncated: truncated))
        }
    }

    func getPane(_ request: ControlRequest) -> ControlReply {
        pane(request.args.pane, for: request).map { place in place.window.listing(of: place.pane, in: place.tab) }
    }

    func waitOnPane(_ request: ControlRequest, hangup: ControlHangup, reply: @escaping (ControlReply) -> Void) {
        let timeout: Int
        switch Self.waitTimeout(request) {
        case .failure(let error): return reply(.failure(error))
        case .success(let seconds): timeout = seconds
        }
        if let problem = Self.outputProblem(request.args.output) { return reply(.failure(problem)) }
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
            if error.code == .notFound, let exit = launchedExit(of: address, for: request) {
                return reply(.success(Self.exited(exit)))
            }
            reply(.failure(error))
        case .success(let place):
            hold(
                waitOn: place, output: request.args.output, timeout: timeout, for: request, hangup: hangup,
                reply: reply)
        }
    }

    static func outputProblem(_ output: String?) -> ControlError? {
        if output?.isEmpty == true { return ControlError(.badRequest, "output must not be empty.") }
        if output?.contains(where: \.isNewline) == true {
            return ControlError(.badRequest, "output matches within one line, so it takes no newline.")
        }
        return nil
    }

    static func waitTimeout(_ request: ControlRequest) -> Result<Int, ControlError> {
        let timeout = request.args.timeout ?? ControlWire.defaultPaneWait
        guard (1...ControlWire.longestPaneWait).contains(timeout) else {
            return .failure(ControlError(.badRequest, "timeout must be 1 to \(ControlWire.longestPaneWait) seconds."))
        }
        return .success(timeout)
    }

    @discardableResult
    func hold(
        waitOn place: PanePlace, output: String?, timeout: Int, for request: ControlRequest, hangup: ControlHangup,
        reply: @escaping (ControlReply) -> Void
    ) -> PaneWait? {
        let caller = request.caller?.pane.flatMap { locate(pane: $0)?.pane.surfaceID }
        let answered: (PaneWait.Answer) -> Void = {
            reply(.success(WaitResult(reason: $0.reason, exitCode: $0.exitCode, text: $0.text, pane: $0.pane)))
        }
        guard let wait = PaneWait(watched(place), caller: caller, output: output, reply: answered) else {
            reply(.failure(ControlError(.notFound, "There is no pane \(place.pane.token).")))
            return nil
        }
        paneWaits.hold(wait, timeout: TimeInterval(timeout), hangup: hangup)
        return wait
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
            exit: { [self] in launchedExit(of: token) },
            awaitsQueuedTask: { [paneDrafts, surfaceID = place.pane.surfaceID] in
                paneDrafts.hasQueuedTask(for: surfaceID)
            })
    }

    func launchedExit(of token: Int) -> LaunchedPaneExit? {
        windows().lazy.compactMap { $0.launchedPaneExits.exit(of: token) }.first
    }

    private func launchedExit(of address: ControlAddress.Pane, for request: ControlRequest) -> LaunchedPaneExit? {
        switch address {
        case .token(let token): return launchedExit(of: token)
        case .name(let name):
            if let parent = request.caller?.pane, let own = latestExit(named: name, startedBy: parent) { return own }
            return windows().compactMap { $0.launchedPaneExits.latestExit(named: name) }.max { $0.token < $1.token }
        }
    }

    private func latestExit(named name: String, startedBy parent: Int) -> LaunchedPaneExit? {
        windows().compactMap { $0.launchedPaneExits.latestExit(named: name, startedBy: parent) }
            .max { $0.token < $1.token }
    }

    static func exited(_ exit: LaunchedPaneExit) -> WaitResult {
        WaitResult(reason: .exited, exitCode: exit.exitCode, text: exit.lastLines, pane: exit.pane ?? closedPane(exit))
    }

    private static func closedPane(_ exit: LaunchedPaneExit) -> ListResult.Pane {
        ListResult.Pane(
            token: exit.token, drawer: nil, title: "", cwd: nil, busy: false, agent: nil, name: exit.record.name,
            parent: exit.record.parent, firstTask: exit.record.firstTask)
    }

    private static func notStarted(_ token: Int) -> ControlError {
        ControlError(.failed, "Pane \(token) has not started.")
    }

    static func viewport(of surface: TerminalSurface) -> String? {
        guard let rows = surface.cellMetrics?.rows, let grid = surface.grid else { return nil }
        let top = grid.viewportTop
        var lines = (top..<top + rows).map { grid.row($0).map(text(of:)) ?? "" }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func text(of row: TerminalGridRow) -> String {
        let written = row.cells.lastIndex { !$0.text.isEmpty }.map { row.cells[...$0] } ?? []
        return written.filter { $0.width > 0 }.map { $0.text.isEmpty ? " " : $0.text }.joined()
    }
}
