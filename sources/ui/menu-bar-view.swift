import SwiftUI

struct MenuBarView: View {
    @ObservedObject var app: AppState

    var body: some View {
        Text("TouchChord · \(app.stateTitle)")
        Text("触摸：\(app.fingerCount) 指")
        Toggle("启用", isOn: $app.enabled)
        Divider()
        Button("紧急释放修饰键") { app.emergencyRelease() }
        Button("重新连接") { app.restart() }
        if app.state == .unavailable {
            Text(app.message)
            Button("辅助功能权限…") { app.requestAccessibility() }
            Button("输入监控权限…") { app.requestInputMonitoring() }
        }
        Divider()
        Button("设置…") {
            SettingsPresenter.show(app: app)
        }
        Button("系统菜单栏设置…") { app.openMenuBarSettings() }
        Toggle("登录时启动", isOn: Binding(get: { app.loginEnabled }, set: app.setLogin))
        Button("退出 TouchChord") { NSApp.terminate(nil) }
        if app.showDebug {
            Divider()
            Text("状态：\(app.state.rawValue)")
            Text(app.message)
        }
    }
}
