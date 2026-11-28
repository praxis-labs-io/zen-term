import AppLog
import Foundation
import IOKit.pwr_mgt

final class IOKitPowerAssertions: PowerAssertions {
    private static let reason = "ZenTerm Keep Awake" as CFString

    private var system: IOPMAssertionID?
    private var display: IOPMAssertionID?

    func hold(keepingDisplayOn: Bool) {
        if system == nil { system = Self.create(kIOPMAssertPreventUserIdleSystemSleep) }
        if keepingDisplayOn, display == nil {
            display = Self.create(kIOPMAssertPreventUserIdleDisplaySleep)
        } else if !keepingDisplayOn {
            Self.drop(&display)
        }
    }

    func release() {
        Self.drop(&system)
        Self.drop(&display)
    }

    deinit { release() }

    private static func create(_ type: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id)
        guard result == kIOReturnSuccess else {
            Log.warning("keep awake: \(type) assertion failed (\(result))", category: .app)
            return nil
        }
        return id
    }

    private static func drop(_ id: inout IOPMAssertionID?) {
        guard let held = id else { return }
        IOPMAssertionRelease(held)
        id = nil
    }
}
