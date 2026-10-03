import Foundation

@testable import ZenTerm

final class FakeSSHWatchers {
    var ready: (@MainActor () -> Void)?
    var appeared: (@MainActor () -> Void)?
    var unwatchable: (@MainActor () -> Void)?
    var found: (@MainActor (pid_t?) -> Void)?
    var exited: (@MainActor () -> Void)?
    var socketWatches = 0
    var cancels = 0
    var exitCancels = 0
    var resolves = 0
    var delayed: [@MainActor () -> Void] = []
    var answerBeforeLogin: pid_t?? = .some(nil)
    var ended: [pid_t] = []
    var onEnd: (() -> Void)?

    var watchers: SSHConnection.Watchers {
        SSHConnection.Watchers(
            awaitSocket: { [self] _, ready, appeared, unwatchable in
                socketWatches += 1
                self.ready = ready
                self.appeared = appeared
                self.unwatchable = unwatchable
                return { [self] in cancels += 1 }
            },
            resolveMaster: { [self] _, _, found in
                resolves += 1
                guard let answer = answerBeforeLogin else { return self.found = found }
                answerBeforeLogin = nil
                found(answer)
            },
            awaitExit: { [self] _, exited in
                self.exited = exited
                return { [self] in exitCancels += 1 }
            },
            after: { [self] _, work in delayed.append(work) },
            endMaster: { [self] pid in
                ended.append(pid)
                onEnd?()
            })
    }

    func connect(pid: pid_t? = 42) {
        appeared?()
        found?(pid)
    }

    func runDelayed() {
        let due = delayed
        delayed = []
        due.forEach { $0() }
    }
}
