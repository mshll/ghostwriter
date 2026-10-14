import Foundation
import IOKit.ps

final class PowerMonitor {
    private(set) var isOnBattery = false
    var onChange: (() -> Void)?

    var prefersEconomy: Bool {
        let info = ProcessInfo.processInfo
        return isOnBattery || info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }

    private var source: CFRunLoopSource?

    func start() {
        update()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.update() }
        }, context)?.takeRetainedValue() else { return }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func update() {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery = type == kIOPSBatteryPowerValue
        guard onBattery != isOnBattery else { return }
        isOnBattery = onBattery
        onChange?()
    }
}
