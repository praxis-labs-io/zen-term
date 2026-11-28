import AppKit
import XCTest

@testable import ZenTerm

final class KeepAwakeToastTests: XCTestCase {
    private let ended: [KeepAwake.Release] = [
        .agentsFinished, .timeUp(30 * 60), .timeUp(60 * 60), .timeUp(2 * 60 * 60), .battery(percent: 9),
    ]
    private let refused: [KeepAwake.Refusal] = [.nothingWorking, .battery(percent: 8, stop: 10)]

    func test_eachRelease_namesItsCause() {
        let messages = ended.map { WindowController.keepAwakeEndedToast($0).message }
        XCTAssertEqual(
            messages,
            [
                "Agents finished.\nYour Mac can sleep again.",
                "The 30 minutes are up.\nYour Mac can sleep again.",
                "The hour is up.\nYour Mac can sleep again.",
                "The 2 hours are up.\nYour Mac can sleep again.",
                "Battery is at 9%.\nYour Mac can sleep again.",
            ])
        XCTAssertEqual(WindowController.keepAwakeEndedToast(.battery(percent: 9)).variant, .warning)
        XCTAssertEqual(WindowController.keepAwakeEndedToast(.agentsFinished).variant, .info)
    }

    func test_aHoldThatNeverStarted_isNotCalledEnded() {
        for refusal in refused {
            XCTAssertEqual(WindowController.keepAwakeRefusedToast(refusal).title, "Keep Awake didn't start")
        }
        XCTAssertEqual(
            WindowController.keepAwakeRefusedToast(.battery(percent: 8, stop: 10)).message,
            "Battery is at 8%, below the 10% stop.")
    }

    func test_copy_fitsTheToastWithoutWrapping() {
        let toasts =
            ended.map(WindowController.keepAwakeEndedToast) + refused.map(WindowController.keepAwakeRefusedToast)
        for toast in toasts {
            for line in (toast.message ?? "").split(separator: "\n") {
                let width = (String(line) as NSString).size(withAttributes: [.font: ToastView.messageFont]).width
                XCTAssertLessThanOrEqual(width, ToastView.messageMaxWidth, "wraps: \(line)")
            }
            let titleWidth = (toast.title as NSString).size(withAttributes: [.font: ToastView.titleFont]).width
            XCTAssertLessThanOrEqual(titleWidth, ToastView.titleMaxWidth, "truncates: \(toast.title)")
        }
    }

    func test_paletteCommands_startTheHoldTheirTitlesName() {
        XCTAssertEqual(AppDelegate.keepAwakeStart(for: .keepAwake)?.until, .turnedOff)
        XCTAssertEqual(AppDelegate.keepAwakeStart(for: .keepAwakeUntilAgentsFinish)?.until, .agentsFinish)
        XCTAssertEqual(AppDelegate.keepAwakeStart(for: .keepAwakeForOneHour)?.until, .duration(60 * 60))
        let display = AppDelegate.keepAwakeStart(for: .keepAwakeWithDisplay)
        XCTAssertNotNil(display)
        XCTAssertNil(display?.until, "keeps the hold's end")
        XCTAssertEqual(display?.display, true)
        XCTAssertNil(AppDelegate.keepAwakeStart(for: .turnOffKeepAwake))
    }
}
