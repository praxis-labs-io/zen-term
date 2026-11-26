import AppKit
import XCTest

@testable import ZenTerm

final class ProcessIconTests: XCTestCase {
    func test_aBrandedProgram_takesItsBrandsChip() {
        let nvim = ProcessIcon.forProgram("nvim")
        XCTAssertEqual(nvim.name, "Neovim")
        XCTAssertEqual(nvim.mark, "neovim")
        guard case .brand = nvim.look else { return XCTFail("Neovim is a brand chip, got \(nvim.look)") }
    }

    func test_severalPrograms_shareOneMark() {
        XCTAssertEqual(ProcessIcon.forProgram("lazygit"), ProcessIcon.forProgram("git"))
        XCTAssertEqual(ProcessIcon.forProgram("k9s"), ProcessIcon.forProgram("kubectl"))
        XCTAssertEqual(ProcessIcon.forProgram("npx"), ProcessIcon.forProgram("npm"))
    }

    func test_everyShell_isTheOnePromptChip_whateverTheShell() {
        for shell in ["zsh", "bash", "fish", "nu", "sh"] {
            XCTAssertEqual(ProcessIcon.forProgram(shell), .shell, shell)
        }
        XCTAssertEqual(ProcessIcon.shell.look, .neutral, "a resting shell never takes brand color")
    }

    func test_noProgram_readsAsTheShell() {
        XCTAssertEqual(ProcessIcon.forProgram(nil), .shell)
        XCTAssertEqual(ProcessIcon.forProgram(""), .shell)
    }

    func test_anUnknownProgram_readsAsTheShell() {
        XCTAssertEqual(ProcessIcon.forProgram("fooctl"), .shell)
    }

    func test_aWaitingCommand_isTheTimer_notTheShell() {
        for waiting in ["sleep", "wait", "watch"] {
            XCTAssertEqual(ProcessIcon.forProgram(waiting).mark, "hourglass", waiting)
        }
    }

    func test_aScript_isNamedForItself_notItsInterpreter() {
        XCTAssertEqual(ProcessIcon.forCommand(["python3", "/opt/venv/bin/pytest", "-x"]).name, "Tests")
        XCTAssertEqual(
            ProcessIcon.forCommand(["/bin/bash", "-pu", "/opt/homebrew/bin/brew", "upgrade"]).name, "Homebrew")
        XCTAssertEqual(ProcessIcon.forCommand(["python3", "-m", "pytest"]).name, "Tests")
    }

    func test_anInterpreterRunningSomethingUnmapped_staysItself() {
        XCTAssertEqual(ProcessIcon.forCommand(["python3", "script.py"]).name, "Python")
        XCTAssertEqual(ProcessIcon.forCommand(["python3", "-c", "print(1)"]).name, "Python")
        XCTAssertEqual(ProcessIcon.forCommand(["-zsh"]), .shell)
        XCTAssertEqual(ProcessIcon.forCommand([]), .shell)
    }

    func test_aVersionedProgram_findsItsUnversionedName() {
        XCTAssertEqual(ProcessIcon.forProgram("python3.12").name, "Python")
        XCTAssertEqual(ProcessIcon.forProgram("Python3").name, "Python", "program names match in any case")
    }

    func test_anAgent_isNamedByAnyOfItsWords() {
        XCTAssertEqual(ProcessIcon.forAgent("Claude Code").name, "Claude Code")
        XCTAssertEqual(ProcessIcon.forAgent("codex").mark, "openai", "Codex is OpenAI's, so its mark is not its name")
        XCTAssertEqual(ProcessIcon.forAgent("pi").name, "Pi")
    }

    func test_anAgentWithNoMark_isTheRobot_andAWordOnlyContainingAnAgentsNameIsNotThatAgent() {
        XCTAssertEqual(ProcessIcon.forAgent("aider"), .unknownAgent)
        XCTAssertEqual(ProcessIcon.forAgent("pip"), .unknownAgent, "pip contains pi but is not Pi")
        XCTAssertEqual(ProcessIcon.forProgram("goose"), .unknownAgent, "an unmarked agent's program is the robot too")
        XCTAssertEqual(ProcessIcon.unknownAgent.mark, "bot")
    }

    func test_anAgentsProgram_findsItsChip_asItsNameDoes() {
        for agent in ["claude", "codex", "gemini", "copilot", "opencode", "pi", "ollama"] {
            XCTAssertEqual(ProcessIcon.forProgram(agent), ProcessIcon.forAgent(agent), agent)
        }
    }

    func test_everyChipsMark_loads_tintableUnlessItCarriesItsOwnColors() throws {
        for icon in ProcessIcon.allForTesting {
            let image = try XCTUnwrap(icon.image, "\(icon.name)'s mark \(icon.mark) is not bundled")
            if case .artwork = icon.look {
                XCTAssertFalse(image.isTemplate, "\(icon.name) draws its own colors, which a tint would flatten")
            } else {
                XCTAssertTrue(image.isTemplate, "\(icon.name) takes its glyph color from the chip")
            }
        }
    }

    func test_noProgramName_isListedTwice() {
        let names = ProcessIcon.programNamesForTesting
        XCTAssertEqual(Set(names).count, names.count, "a duplicate name means one of its chips is never reached")
    }

    func test_everyPickedBrandMark_takesItsBrandsChip_notTheToolsTint() throws {
        for mark in IconCatalog.brands {
            let icon = try XCTUnwrap(ProcessIcon.toolFloat(probe(icon: mark)), mark)
            switch icon.look {
            case .brand, .artwork: break
            default: XCTFail("\(mark) draws as \(icon.look)")
            }
            XCTAssertEqual(icon.name, "Probe", "named by its float, not the brand")
            XCTAssertNotNil(icon.image, mark)
        }
    }

    func test_pickedGemini_drawsInGeminisOwnColors() throws {
        let icon = try XCTUnwrap(ProcessIcon.toolFloat(probe(icon: "gemini")))
        XCTAssertEqual(icon.mark, "gemini-color")
        XCTAssertEqual(icon.look, ProcessIcon.forAgent("gemini").look)
    }

    func test_aPickedSymbol_keepsTheToolsTint() throws {
        let icon = try XCTUnwrap(ProcessIcon.toolFloat(probe(icon: "hammer")))
        guard case .catalog = icon.look else { return XCTFail("a symbol draws as \(icon.look)") }
    }

    private func probe(icon: String) -> ToolFloat {
        ToolFloat(
            id: "probe", order: 1, title: "Probe", icon: icon, command: "true", dir: nil,
            widthFraction: 0.6, heightFraction: 0.6, requiresGitRepo: false, persist: .window,
            toggle: Chord(command: true, control: true, key: "p"))
    }
}
