import UIKit

struct DeviceInfo: Sendable {
    @MainActor
    static func collect() -> DeviceRegistration {
        let device = UIDevice.current
        return DeviceRegistration(
            identifierForVendor: device.identifierForVendor?.uuidString ?? "unknown",
            deviceName: device.name,
            deviceModel: device.model,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? "unknown",
            watchModel: nil,
            watchOsVersion: nil
        )
    }
}
