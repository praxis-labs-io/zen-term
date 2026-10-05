import XCTest

@testable import ZenTerm

final class SSHHostProbeTests: XCTestCase {
    enum Answer {
        case online
        case offline
        case proxied
    }

    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var queued: [String: [Answer]] = [:]
        private var asked: [String] = []
        private var resolved: [String] = []
        private var gate: (host: String, semaphore: DispatchSemaphore)?

        func holdNextResolve(of host: String) -> DispatchSemaphore {
            let gate = DispatchSemaphore(value: 0)
            lock.withLock { self.gate = (host, gate) }
            return gate
        }

        func queue(_ answers: [Answer], for host: String) {
            lock.withLock { queued[host] = answers }
        }

        func resolve(_ host: String) -> SSHHostResolver.Resolution? {
            SSHHostResolver.Resolution(endpoint: endpoint(host), destination: "drew@\(host).lan")
        }

        private func endpoint(_ host: String) -> SSHHostResolver.Endpoint? {
            let held: DispatchSemaphore? = lock.withLock {
                resolved.append(host)
                guard let held = gate, held.host == host else { return nil }
                gate = nil
                return held.semaphore
            }
            held?.wait()
            return lock.withLock {
                if queued[host]?.first == .proxied {
                    asked.append(host)
                    return .proxied
                }
                return .direct(hostname: host, port: 22)
            }
        }

        func banner(_ host: String) -> Bool {
            lock.withLock {
                asked.append(host)
                let answers = queued[host] ?? [.online]
                if answers.count > 1 { queued[host] = Array(answers.dropFirst()) }
                return answers[0] == .online
            }
        }

        func askCount(_ host: String) -> Int { lock.withLock { asked.filter { $0 == host }.count } }
        func resolveCount(_ host: String) -> Int { lock.withLock { resolved.filter { $0 == host }.count } }
    }

    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        var value: Int { lock.withLock { attempts } }

        func count(_ host: String) -> SSHHostResolver.Resolution? {
            if host == "ghost" { lock.withLock { attempts += 1 } }
            return nil
        }
    }

    private let answers = Answers()
    private var configDir: URL!
    private let center = SSHHostStatusCenter()
    private var probe: SSHHostProbe!

    override func setUpWithError() throws {
        try super.setUpWithError()
        configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "Include extra\nHost devbox\n".write(
            to: configDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host other\n".write(to: configDir.appendingPathComponent("extra"), atomically: true, encoding: .utf8)
        SSHConfigHosts.userConfigOverrideForTesting = configDir.appendingPathComponent("config")
        let answers = self.answers
        SSHHostProbe.resolveOverrideForTesting = { answers.resolve($0) }
        SSHHostProbe.bannerOverrideForTesting = { host, _ in answers.banner(host) }
        probe = SSHHostProbe(center: center)
    }

    override func tearDown() {
        SSHConfigHosts.userConfigOverrideForTesting = nil
        try? FileManager.default.removeItem(at: configDir)
        SSHHostProbe.resolveOverrideForTesting = nil
        SSHHostProbe.bannerOverrideForTesting = nil
        probe = nil
        super.tearDown()
    }

    private func status(_ host: String) -> SSHHostStatus { center.status(of: SSHHostID(alias: host)) }

    func test_addedHosts_areProbedAndTheirAnswersLand() {
        answers.queue([.offline], for: "down")
        answers.queue([.proxied], for: "inner")

        probe.setHosts(["up", "down", "inner"], off: [])

        waitUntil(answers.askCount("down") == 1 && answers.askCount("inner") == 1, "the round")
        waitUntil(status("up") == .online && status("inner") == .online, "the answers to land")
        XCTAssertEqual(status("down"), .offline)
    }

    func test_aConnectedHost_isNotProbed() {
        center.setConnected(true, host: SSHHostID(alias: "live"))
        answers.queue([.offline], for: "other")

        probe.setHosts(["live", "other"], off: [])

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
            MainActor.assumeIsolated {
                let host = SSHHostID(alias: "devbox")
                if center.destination(of: host) != nil { seen.append(center.status(of: host)) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let gate = answers.holdNextResolve(of: "devbox")
        probe.setHosts(["devbox"], off: [])
        waitUntil(answers.resolveCount("devbox") == 1, "the first round to start")
        probe.networkChanged(isUp: true)
        gate.signal()

        waitUntil(answers.askCount("devbox") >= 2, "the host to be asked again")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(status("devbox"), .online)
        XCTAssertFalse(seen.contains(.offline), "the stale Offline never showed")
    }

    func test_losingTheNetwork_takesDirectHostsOfflineAndLeavesJumpHostsOnline() {
        answers.queue([.proxied], for: "inner")
        probe.setHosts(["devbox", "inner"], off: [])
        waitUntil(answers.askCount("devbox") == 1 && answers.askCount("inner") == 1, "the first round")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        probe.networkChanged(isUp: false)

        XCTAssertEqual(status("devbox"), .offline)
        XCTAssertEqual(status("inner"), .online)
    }

    func test_noHostIsConnectedTo_whileTheNetworkIsDown() {
        probe.setHosts(["devbox"], off: [])
        waitUntil(answers.askCount("devbox") == 1, "the first round")
        probe.networkChanged(isUp: false)

        probe.probeAll()

        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(answers.askCount("devbox"), 1)
    }

    func test_aRemovedHost_forgetsItsReachability() {
        probe.setHosts(["devbox"], off: [])
        waitUntil(status("devbox") == .online, "the host to read Online")

        probe.setHosts([], off: [])

        XCTAssertEqual(status("devbox"), .offline)
    }

    func test_aWatchStartedAfterTheNetworkWentDown_probesAgain() {
        probe.setHosts(["first"], off: [])
        probe.networkChanged(isUp: false)
        probe.setHosts([], off: [])

        probe.setHosts(["devbox"], off: [])

        waitUntil(answers.askCount("devbox") == 1, "the new watch to probe")
    }

    func test_aNewMonitorsFirstReport_ofNoNetwork_takesHostsOffline() {
        probe.setHosts(["devbox"], off: [])
        waitUntil(answers.askCount("devbox") == 1, "the first round")

        probe.firstPathReported(isUp: false)

        XCTAssertEqual(status("devbox"), .offline)
    }

    func test_aNewMonitorsFirstReport_ofTheNetworkItAssumed_startsNoRound() {
        probe.setHosts(["devbox"], off: [])
        waitUntil(answers.askCount("devbox") == 1, "the first round")

        probe.firstPathReported(isUp: true)

        RunLoop.current.run(until: Date().addingTimeInterval(1.3))
        XCTAssertEqual(answers.askCount("devbox"), 1)
    }

    func test_aSecondRound_reusesTheResolvedEndpoint() {
        probe.setHosts(["devbox"], off: [])
        waitUntil(answers.askCount("devbox") == 1, "the first round")

        probe.probeAll()

        waitUntil(answers.askCount("devbox") == 2, "the second round")
        XCTAssertEqual(answers.resolveCount("devbox"), 1)
    }

    func test_aResolvedHost_publishesWhereSSHWillSignIn_fromTheSameResolution() {
        probe.setHosts(["devbox"], off: [])
        waitUntil(center.destination(of: SSHHostID(alias: "devbox")) == "drew@devbox.lan", "the destination to land")

        probe.probeAll()

        waitUntil(answers.askCount("devbox") == 2, "the second round")
        XCTAssertEqual(answers.resolveCount("devbox"), 1, "the destination must not cost a second ssh -G")
    }

    func test_aRemovedHost_forgetsItsDestination() {
        probe.setHosts(["ghost"], off: [])
        waitUntil(center.destination(of: SSHHostID(alias: "ghost")) != nil, "the destination to land")

        probe.setHosts([], off: [])

        XCTAssertNil(center.destination(of: SSHHostID(alias: "ghost")))
    }

    private func destination(_ host: String) -> String? { center.destination(of: SSHHostID(alias: host)) }

    func test_aConfigHostThatIsNotOn_isResolvedWithoutBeingProbed() {
        probe.setHosts([], off: [])
        center.requestDestinations(of: [])

        waitUntil(destination("devbox") == "drew@devbox.lan" && destination("other") == "drew@other.lan", "both")

        XCTAssertEqual(answers.askCount("devbox"), 0)
        XCTAssertEqual(status("devbox"), .offline)
    }

    func test_anOffAlias_isResolvedWithoutBeingProbed() {
        probe.setHosts([], off: ["ghost"])
        center.requestDestinations(of: [])

        waitUntil(destination("ghost") == "drew@ghost.lan", "the destination to land")

        XCTAssertEqual(answers.askCount("ghost"), 0)
        XCTAssertEqual(status("ghost"), .offline)
    }

    func test_anOffHost_isResolvedOnceAcrossRounds() {
        probe.setHosts([], off: ["ghost"])
        center.requestDestinations(of: [])
        waitUntil(destination("ghost") != nil, "the destination to land")

        probe.probeAll()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(answers.resolveCount("ghost"), 1)
    }

    func test_aHostTurnedOff_keepsItsDestinationAndLosesItsStatus() {
        probe.setHosts(["ghost"], off: [])
        center.requestDestinations(of: ["ghost"])
        waitUntil(status("ghost") == .online && destination("ghost") != nil, "the host to read Online")

        probe.setHosts([], off: ["ghost"])

        XCTAssertEqual(destination("ghost"), "drew@ghost.lan")
        XCTAssertEqual(status("ghost"), .offline)
        let asked = answers.askCount("ghost")
        probe.probeAll()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(answers.askCount("ghost"), asked, "an Off host is never asked again")
    }

    func test_aHostTurnedBackOn_keepsItsDestinationUntilItIsProbed() {
        probe.setHosts([], off: ["ghost"])
        center.requestDestinations(of: [])
        waitUntil(destination("ghost") != nil, "the destination to land")

        probe.setHosts(["ghost"], off: [])

        XCTAssertEqual(destination("ghost"), "drew@ghost.lan")
        waitUntil(status("ghost") == .online, "the host to read Online")
    }

    func test_anOffAliasRemoved_forgetsItsDestination() {
        probe.setHosts([], off: ["ghost"])
        center.requestDestinations(of: [])
        waitUntil(destination("ghost") != nil, "the destination to land")

        probe.setHosts([], off: [])

        XCTAssertNil(destination("ghost"))
    }

    func test_aConfigHostTurnedOff_keepsItsDestination() {
        probe.setHosts(["devbox"], off: [])
        center.requestDestinations(of: ["devbox"])
        waitUntil(destination("devbox") != nil, "the destination to land")

        probe.setHosts([], off: [])

        XCTAssertEqual(destination("devbox"), "drew@devbox.lan")
    }

    func test_aNetworkChange_resolvesAgain() {
        probe.setHosts(["devbox"], off: [])
        waitUntil(answers.askCount("devbox") == 1, "the first round")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        probe.networkChanged(isUp: true)

        waitUntil(answers.askCount("devbox") == 2, "the settled round")
        XCTAssertEqual(answers.resolveCount("devbox"), 2)
    }

    func test_aHostsChange_keepsTheResolutionOfHostsStillListed() {
        probe.setHosts(["devbox"], off: [])
        waitUntil(answers.askCount("devbox") == 1, "the first round")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        probe.setHosts(["devbox", "other"], off: [])
        probe.probeAll()

        waitUntil(answers.askCount("devbox") == 2, "the next round")
        XCTAssertEqual(answers.resolveCount("devbox"), 1)
    }

    func test_aHostThatLeft_isResolvedAgainWhenItReturns() {
        probe.setHosts(["ghost"], off: [])
        waitUntil(answers.askCount("ghost") == 1, "the first round")
        probe.setHosts([], off: [])

        probe.setHosts(["ghost"], off: [])

        waitUntil(answers.askCount("ghost") == 2, "the second round")
        XCTAssertEqual(answers.resolveCount("ghost"), 2)
    }

    func test_beforeSettingsAsks_noOffHostIsResolved() {
        probe.setHosts([], off: ["ghost"])
        probe.probeAll()

        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(answers.resolveCount("ghost"), 0)
        XCTAssertEqual(answers.resolveCount("devbox"), 0)
        XCTAssertNil(destination("ghost"))
    }

    func test_aRequestedHostNoConfigNamesYet_isResolved() {
        probe.setHosts([], off: [])

        center.requestDestinations(of: ["ghost"])

        waitUntil(destination("ghost") == "drew@ghost.lan", "the destination to land")
    }

    func test_askingAgain_resolvesNothingAlreadyResolved() {
        probe.setHosts([], off: ["ghost"])
        center.requestDestinations(of: ["ghost"])
        waitUntil(destination("ghost") != nil, "the destination to land")

        center.requestDestinations(of: ["ghost"])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(answers.resolveCount("ghost"), 1)
    }

    func test_anOffHostWhoseResolutionFails_isNotAskedAgainEveryRound() {
        let attempts = Attempts()
        SSHHostProbe.resolveOverrideForTesting = { attempts.count($0) }
        probe.setHosts([], off: ["ghost"])
        center.requestDestinations(of: [])
        waitUntil(attempts.value == 1, "the first attempt")

        probe.probeAll()
        probe.probeAll()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(attempts.value, 1)
    }

    func test_aFailedOffHost_isAskedAgainAfterANetworkChange() {
        let attempts = Attempts()
        SSHHostProbe.resolveOverrideForTesting = { attempts.count($0) }
        probe.setHosts([], off: ["ghost"])
        center.requestDestinations(of: [])
        waitUntil(attempts.value == 1, "the first attempt")

        probe.networkChanged(isUp: true)

        waitUntil(attempts.value == 2, "the attempt after the change")
    }

    func test_aConnectedHost_isResolvedAgainAfterAConfigEdit_withoutBeingProbed() throws {
        center.setConnected(true, host: SSHHostID(alias: "devbox"))
        probe.setHosts(["devbox"], off: [])
        waitUntil(destination("devbox") == "drew@devbox.lan", "the destination to land")
        SSHHostProbe.resolveOverrideForTesting = { _ in
            SSHHostResolver.Resolution(endpoint: nil, destination: "drew@moved.lan")
        }

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: configDir.appendingPathComponent("extra").path)
        probe.probeAll()

        waitUntil(destination("devbox") == "drew@moved.lan", "the new destination")
        XCTAssertEqual(answers.askCount("devbox"), 0)
        XCTAssertEqual(status("devbox"), .connected)
    }

    func test_aHostTurnedOnWhileItsOffResolutionIsInFlight_isProbedWhenItLands() {
        probe.setHosts([], off: ["ghost"])
        let gate = answers.holdNextResolve(of: "ghost")
        center.requestDestinations(of: [])
        waitUntil(answers.resolveCount("ghost") == 1, "the Off resolution to start")

        probe.setHosts(["ghost"], off: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(status("ghost"), .offline)
        gate.signal()

        waitUntil(status("ghost") == .online, "the host to read Online")
        XCTAssertEqual(answers.resolveCount("ghost"), 1)
    }

    func test_theSameHostsAgain_keepTheirResolution() {
        probe.setHosts(["devbox"], off: [])
        waitUntil(answers.askCount("devbox") == 1, "the first round")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        probe.setHosts(["devbox"], off: [])
        probe.probeAll()

        waitUntil(answers.askCount("devbox") == 2, "the next round")
        XCTAssertEqual(answers.resolveCount("devbox"), 1, "renaming a host must not cost another ssh -G")
    }

    func test_aWake_waitsForTheNetworkToSettleBeforeProbing() {
        probe.setHosts(["devbox"], off: [])
        waitUntil(answers.askCount("devbox") == 1, "the first round")

        probe.systemDidWake()

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(answers.askCount("devbox"), 1, "nothing is asked while the interface comes back")
        waitUntil(answers.askCount("devbox") == 2, "the settled round")
    }

    func test_aJumpHostResolvedAfterTheNetworkDrops_stillReadsOnline() {
        answers.queue([.proxied], for: "inner")
        let gate = answers.holdNextResolve(of: "inner")
        probe.setHosts(["inner"], off: [])
        waitUntil(answers.resolveCount("inner") == 1, "the first resolution to start")

        probe.networkChanged(isUp: false)
        gate.signal()

        waitUntil(answers.resolveCount("inner") == 2, "the host to be resolved again")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(status("inner"), .online)
    }

    func test_anEditToAnIncludedConfigFile_resolvesAgain_andAnUntouchedConfigDoesNot() throws {
        probe.setHosts(["devbox"], off: [])
        waitUntil(answers.askCount("devbox") == 1, "the first round")
        probe.probeAll()
        waitUntil(answers.askCount("devbox") == 2, "a round with the config untouched")
        XCTAssertEqual(answers.resolveCount("devbox"), 1)

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: configDir.appendingPathComponent("extra").path)
        probe.probeAll()

        waitUntil(answers.askCount("devbox") == 3, "a round after the edit")
        XCTAssertEqual(answers.resolveCount("devbox"), 2)
    }
}
