import SwiftUI

@MainActor
final class SettingsPresenter: NSObject, NSWindowDelegate {
    private static let shared = SettingsPresenter()
    private var window: NSWindow?

    static func show(app: AppState) {
        shared.showWindow(app: app)
    }

    private func showWindow(app: AppState) {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(app: app))
            let window = NSWindow(contentViewController: controller)
            window.title = "TouchChord 设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // 设置窗口参与正常应用切换；否则系统设置关闭时可能回到更早的普通应用，遮住本窗口。
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // 用户主动关闭设置后恢复纯菜单栏运行，不占据 Dock。
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppState
    var body: some View {
        Form {
            Section("三指触摸 → Command") {
                Toggle("启用 TouchChord", isOn: $app.enabled)
                Toggle("三指触摸触发", isOn: $app.threeFingerEnabled)
                HStack {
                    Text("激活防抖")
                    Slider(value: $app.debounceMilliseconds, in: 0...200, step: 5)
                    Text("\(Int(app.debounceMilliseconds)) ms").monospacedDigit().frame(width: 60)
                }
                Text("三指或更多时保持 ⌘；少于三指立即释放。Escape 可在模拟按住时紧急释放。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("系统集成") {
                Button("系统菜单栏设置…") { app.openMenuBarSettings() }
                Text("图标显示由系统管理：菜单栏 → 允许在菜单栏中显示 → TouchChord。隐藏后仍可重新打开 TouchChord 进入设置。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("登录时启动", isOn: Binding(get: { app.loginEnabled }, set: app.setLogin))
                Text(app.loginMessage).font(.caption)
                LabeledContent("辅助功能", value: app.accessibilityGranted ? "已授权" : "未授权")
                LabeledContent("输入监控", value: app.inputGranted ? "已授权" : "未授权")
                HStack {
                    Button("授权辅助功能…") { app.requestAccessibility() }
                    Button("授权输入监控…") { app.requestInputMonitoring() }
                    Button("重新检查并连接") { app.restart() }
                }
                Text("授权时若系统要求退出，请重新打开 TouchChord 继续设置；返回 TouchChord 会自动检查权限。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("状态") {
                Text("\(app.stateTitle) · \(app.fingerCount) 指")
                Text(app.message).font(.caption).textSelection(.enabled)
                Toggle("显示调试信息", isOn: $app.showDebug)
                Button("紧急释放 ⌘") { app.emergencyRelease() }
            }
            Text("使用 Apple 私有触控板 API，仅在当前开发设备验证。系统升级后请重新验证；不保证进程被强制杀死时仍能执行清理。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 600)
        .onAppear { app.refreshPermissions(); app.refreshLogin() }
    }
}
