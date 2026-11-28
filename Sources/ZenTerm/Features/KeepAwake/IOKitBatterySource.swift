import Foundation
import IOKit.ps

final class IOKitBatterySource: BatterySource {
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard
            let created = IOPSNotificationCreateRunLoopSource(
                { context in
                    guard let context else { return }
                    Unmanaged<IOKitBatterySource>.fromOpaque(context).takeUnretainedValue().onChange?()
                }, context)?.takeRetainedValue()
        else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        source = created
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    var reading: BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        for item in list {
            guard
                let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue()
                    as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return BatteryReading(
                isOnBattery: providing == kIOPSBatteryPowerValue, percent: current * 100 / max)
        }
        return nil
    }
}
