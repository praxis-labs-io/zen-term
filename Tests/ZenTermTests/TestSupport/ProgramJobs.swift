import Foundation
import XCTest

@testable import ZenTerm

// Real processes whose argv[0] is a chosen name, which is how a pane's program is read.
final class ProgramJobs {
    private var jobs: [Process] = []

    func start(named name: String, file: StaticString = #filePath, line: UInt = #line) throws -> pid_t {
        let job = Process()
        job.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        job.arguments = ["-e", "exec {'/bin/sleep'} '\(name)', '30'"]
        try job.run()
        jobs.append(job)
        let pid = job.processIdentifier
        let deadline = Date().addingTimeInterval(5)
        while ProcessArguments.programName(of: pid) != name, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(
            ProcessArguments.programName(of: pid), name, "precondition: the job runs as \(name)", file: file, line: line
        )
        return pid
    }

    func track(_ job: Process) { jobs.append(job) }

    func stopAll() {
        jobs.forEach { $0.terminate() }
        jobs = []
    }
}
