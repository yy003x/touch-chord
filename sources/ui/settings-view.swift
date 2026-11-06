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
            Section("触摸按键") {
                Toggle("启用 TouchChord", isOn: $app.enabled)
                modifierPicker("2 指触摸", selection: $app.twoFingerKey)
                modifierPicker("3 指触摸", selection: $app.threeFingerKey)
                modifierPicker("4 指触摸", selection: $app.fourFingerKey)
                HStack {
                    Text("激活防抖")
                    Slider(value: $app.debounceMilliseconds, in: 0...200, step: 5)
                    Text("\(Int(app.debounceMilliseconds)) ms").monospacedDigit().frame(width: 60)
                }
                Text("精确匹配手指数；换档先释放旧键再激活新键。0、1、5 指及以上不触发。Escape 紧急释放后须全部抬起再触摸。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("修饰键持续按住；回车、Esc 每次稳定触摸触发一次，不连发。同名物理键按住时跳过触发。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("轻点来点按", value: app.tapClickStatus.title)
                Button("打开触控板设置…") { app.openTrackpadSettings() }
                Text("请先关闭系统“轻点来点按”。两指滚动、缩放和多指系统手势仍可能冲突，本功能不会屏蔽这些手势。")
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
                Button("紧急释放修饰键") { app.emergencyRelease() }
            }
            Text("使用 Apple 私有触控板 API，仅在当前开发设备验证。系统升级后请重新验证；不保证进程被强制杀死时仍能执行清理。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 760)
        .onAppear { app.refreshPermissions(); app.refreshLogin(); app.refreshTouchPreference() }
    }

    private func modifierPicker(_ title: String, selection: Binding<TouchKey?>) -> some View {
        Picker(title, selection: selection) {
            ForEach(TouchKey.allCases) { key in Text(key.title).tag(Optional(key)) }
            Text("不触发").tag(TouchKey?.none)
        }
        .pickerStyle(.menu)
    }
}
