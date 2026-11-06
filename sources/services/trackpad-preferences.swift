import Foundation

enum TapClickStatus: Equatable {
    case disabled, enabled, unknown

    var title: String {
        switch self {
        case .disabled: "已关闭"
        case .enabled: "已开启，请先关闭"
        case .unknown: "无法确认，请检查后重新连接"
        }
    }

    static func read() -> TapClickStatus {
        // Clicking 是当前设备验证的系统偏好键，并非 Apple 承诺稳定的公开契约。
        let domain = "com.apple.AppleMultitouchTrackpad" as CFString
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              let value = CFPreferencesCopyValue("Clicking" as CFString, domain,
                                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              CFGetTypeID(value) == CFBooleanGetTypeID() || CFGetTypeID(value) == CFNumberGetTypeID(),
              let number = value as? NSNumber, number.intValue == 0 || number.intValue == 1 else {
            return .unknown
        }
        return number.boolValue ? .enabled : .disabled
    }
}
