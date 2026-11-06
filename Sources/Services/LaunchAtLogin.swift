import ServiceManagement

enum LaunchAtLogin {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "登录时自动启动"
        case .requiresApproval: "请在系统设置 → 通用 → 登录项中批准 TouchChord"
        case .notRegistered: "未启用登录启动"
        case .notFound: "系统尚未找到登录启动服务；请将 TouchChord.app 放在固定位置后启用"
        @unknown default: "登录启动状态未知"
        }
    }
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
