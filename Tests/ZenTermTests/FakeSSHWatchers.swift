import Foundation

@testable import ZenTerm

final class FakeSSHWatchers {
    var ready: (@MainActor () -> Void)?
    var appeared: (@MainActor () -> Void)?
    var found: (@MainActor (pid_t?) -> Void)?
    var exited: (@MainActor () -> Void)?
    var socketWatches = 0
    var cancels = 0
    var exitCancels = 0

    var watchers: SSHConnection.Watchers {
        SSHConnection.Watchers(
            awaitSocket: { [self] _, ready, appeared in
                socketWatches += 1
                self.ready = ready
                self.appeared = appeared
                return { [self] in cancels += 1 }
            },
            checkMaster: { [self] _, _, found in self.found = found },
            awaitExit: { [self] _, exited in
                self.exited = exited
                return { [self] in exitCancels += 1 }
            })
    }

    func connect(pid: pid_t? = 42) {
        appeared?()
        found?(pid)
    }
}
