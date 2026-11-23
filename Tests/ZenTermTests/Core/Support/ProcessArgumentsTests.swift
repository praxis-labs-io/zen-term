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

    func test_combinedAndLongInlineCodeFlags_areNamedForTheirInterpreter() {
        XCTAssertEqual(ProcessArguments.commandName(from: ["bash", "-lc", "cd /tmp/foo && make"]), "bash")
        XCTAssertEqual(ProcessArguments.commandName(from: ["node", "-p", "process.version"]), "node")
        XCTAssertEqual(ProcessArguments.commandName(from: ["node", "--eval=console.log(1)"]), "node")
        XCTAssertEqual(ProcessArguments.commandName(from: ["perl", "-wE", "say 1"]), "perl")
    }

    func test_aFlagsValue_isNeverTheScript() {
        XCTAssertEqual(ProcessArguments.commandName(from: ["python3", "-W", "ignore", "train.py"]), "train.py")
        XCTAssertEqual(ProcessArguments.commandName(from: ["bash", "-o", "pipefail", "./deploy.sh"]), "deploy.sh")
        XCTAssertEqual(ProcessArguments.commandName(from: ["python3", "-m", "pytest"]), "pytest")
        XCTAssertEqual(ProcessArguments.commandName(from: ["python3", "-u", "serve"]), "python3")
    }

    func test_aShellStartedAtAPrompt_isInteractive_butAScriptOrInlineCodeIsNot() {
        XCTAssertTrue(ProcessArguments.isInteractiveShell(["zsh"]))
        XCTAssertTrue(ProcessArguments.isInteractiveShell(["-zsh"]))
        XCTAssertTrue(ProcessArguments.isInteractiveShell(["bash", "--rcfile", "/tmp/nix-shell.rc"]))
        XCTAssertFalse(ProcessArguments.isInteractiveShell(["bash", "./deploy.sh"]))
        XCTAssertFalse(ProcessArguments.isInteractiveShell(["bash", "-c", "make"]))
        XCTAssertFalse(ProcessArguments.isInteractiveShell(["python3"]))
    }
}
