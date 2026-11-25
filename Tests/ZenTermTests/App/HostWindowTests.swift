import AppKit
import XCTest

@testable import ZenTerm

@MainActor
final class HostWindowTests: WindowTestCase {
    private var originalConfig: GeneralConfig!

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
    }

    override func tearDown() {
        GeneralConfig.setCurrentForTesting(originalConfig)
        super.tearDown()
    }

    private func makeWindow(windowChrome: Bool) -> HostWindow {
        var config = GeneralConfig.builtIn
        config.windowChrome = windowChrome
        GeneralConfig.setCurrentForTesting(config)
        return HostWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    private func buttonsHidden(_ window: HostWindow) -> [Bool] {
        [.closeButton, .miniaturizeButton, .zoomButton].map {
            window.standardWindowButton($0)?.isHidden ?? true
        }
    }

    func test_windowChromeOn_showsTrafficLights() {
        let window = makeWindow(windowChrome: true)
        XCTAssertEqual(buttonsHidden(window), [false, false, false])
    }

    func test_windowChromeOff_hidesTrafficLights() {
        let window = makeWindow(windowChrome: false)
        XCTAssertEqual(buttonsHidden(window), [true, true, true])
    }

    func test_aLiveWindowChromeChange_showsAndHidesTheButtons() {
        let window = makeWindow(windowChrome: false)
        var config = GeneralConfig.builtIn
        config.windowChrome = true
        GeneralConfig.setCurrentForTesting(config)
        window.reapplyWindowChrome()
        XCTAssertEqual(buttonsHidden(window), [false, false, false])
        config.windowChrome = false
        GeneralConfig.setCurrentForTesting(config)
        window.reapplyWindowChrome()
        XCTAssertEqual(buttonsHidden(window), [true, true, true])
    }
}
