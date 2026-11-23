import XCTest

@testable import ZenTerm

final class ProcessArgumentsTests: XCTestCase {
    func test_aProgramIsNamedForItsArgvZero() {
        XCTAssertEqual(ProcessArguments.commandName(from: ["/opt/homebrew/bin/nvim", "App.swift"]), "nvim")
        XCTAssertEqual(ProcessArguments.commandName(from: ["-zsh"]), "zsh")
    }

    func test_aScriptIsNamedForItself_notItsInterpreter() {
        XCTAssertEqual(
            ProcessArguments.commandName(from: ["/bin/bash", "-pu", "/opt/homebrew/bin/brew", "up"]), "brew")
        XCTAssertEqual(ProcessArguments.commandName(from: ["python3.12", "manage.py", "runserver"]), "manage.py")
    }

    func test_inlineCode_isNamedForItsInterpreter() {
        XCTAssertEqual(ProcessArguments.commandName(from: ["bash", "-c", "sleep 30"]), "bash")
        XCTAssertEqual(ProcessArguments.commandName(from: ["perl", "-e", "print 1"]), "perl")
    }
}
