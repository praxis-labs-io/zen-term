import XCTest

@testable import ZenTerm

final class SSHHostProbeTests: XCTestCase {
    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var queued: [String: [SSHHostProbe.Answer]] = [:]
        private var asked: [String] = []

        func queue(_ answers: [SSHHostProbe.Answer], for host: String) {
            lock.withLock { queued[host] = answers }
        }

        func answer(_ host: String) -> SSHHostProbe.Answer {
            lock.withLock {
                asked.append(host)
                let answers = queued[host] ?? [.online]
                if answers.count > 1 { queued[host] = Array(answers.dropFirst()) }
                return answers[0]
            }
        }

        func askCount(_ host: String) -> Int { lock.withLock { asked.filter { $0 == host }.count } }
    }

    private let answers = Answers()
    private let center = SSHHostStatusCenter()
    private var probe: SSHHostProbe!

    override func setUp() {
        super.setUp()
        let answers = self.answers
        SSHHostProbe.answerOverrideForTesting = { answers.answer($0) }
        probe = SSHHostProbe(center: center)
    }

    override func tearDown() {
        SSHHostProbe.answerOverrideForTesting = nil
        probe = nil
        super.tearDown()
    }

    private func status(_ host: String) -> SSHHostStatus { center.status(of: SSHHostID(name: host)) }

    func test_addedHosts_areProbedAndTheirAnswersLand() {
        answers.queue([.offline], for: "down")
        answers.queue([.proxied], for: "inner")

        probe.setHosts(["up", "down", "inner"])

        waitUntil(status("down") == .offline, "the unreachable host to read Offline")
        XCTAssertEqual(status("up"), .online)
        XCTAssertEqual(status("inner"), .online, "a jump host reads Online")
    }

    func test_aConnectedHost_isNotProbed() {
        center.setConnected(true, host: SSHHostID(name: "live"))
        answers.queue([.offline], for: "other")

        probe.setHosts(["live", "other"])

        waitUntil(status("other") == .offline, "the round to land")
        XCTAssertEqual(answers.askCount("live"), 0)
        XCTAssertEqual(status("live"), .connected)
    }

    func test_anAnswerFromBeforeANetworkChange_isDroppedAndAskedAgain() {
        answers.queue([.offline, .online], for: "devbox")
        var seen: [SSHHostStatus] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .sshHostStatusDidChange, object: nil, queue: nil
        ) { [center] _ in
            MainActor.assumeIsolated { seen.append(center.status(of: SSHHostID(name: "devbox"))) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        probe.setHosts(["devbox"])
        probe.networkChanged(isUp: true)

        waitUntil(answers.askCount("devbox") >= 2, "the host to be asked again")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(status("devbox"), .online)
        XCTAssertFalse(seen.contains(.offline), "the stale Offline never showed")
    }

    func test_losingTheNetwork_takesDirectHostsOfflineAndLeavesJumpHostsOnline() {
        answers.queue([.proxied], for: "inner")
        probe.setHosts(["devbox", "inner"])
        waitUntil(answers.askCount("devbox") == 1 && answers.askCount("inner") == 1, "the first round")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        probe.networkChanged(isUp: false)

        XCTAssertEqual(status("devbox"), .offline)
        XCTAssertEqual(status("inner"), .online)
    }

    func test_noRoundRuns_whileTheNetworkIsDown() {
        probe.networkChanged(isUp: false)

        probe.setHosts(["devbox"])
        probe.probeAll()

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(answers.askCount("devbox"), 0)
    }

    func test_aRemovedHost_forgetsItsReachability() {
        answers.queue([.offline], for: "devbox")
        probe.setHosts(["devbox"])
        waitUntil(status("devbox") == .offline, "the host to read Offline")

        probe.setHosts([])

        XCTAssertEqual(status("devbox"), .online)
    }
}
