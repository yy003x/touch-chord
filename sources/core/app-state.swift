import AppKit
import ApplicationServices
import Combine
import TriKeyHardware

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled"); restart() }
    }
    @Published var threeFingerEnabled: Bool {
        didSet { UserDefaults.standard.set(threeFingerEnabled, forKey: "threeFingerEnabled"); restart() }
    }
    @Published var debounceMilliseconds: Double {
        didSet {
            machine.debounce = debounceMilliseconds / 1000
            UserDefaults.standard.set(debounceMilliseconds, forKey: "debounceMilliseconds")
        }
    }
    @Published var showDebug: Bool {
        didSet { UserDefaults.standard.set(showDebug, forKey: "showDebug") }
    }
    @Published private(set) var state: TouchStateMachine.State = .disabled
    @Published private(set) var fingerCount = 0
    @Published private(set) var message = "启动后请先抬起触控板手指"
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputGranted = false
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginMessage = ""
    private var machine = TouchStateMachine()
    private var monitor: MultitouchBridge?
    private var keyboard: ModifierKeyController?
    private var watchdog: Timer?
    private var observers: [NSObjectProtocol] = []
    private var generation = UUID()
    private var suspended = false
    private var started = false
    private var pressedAt = 0.0
    private var lastDeviceTimestamp: Double?

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        threeFingerEnabled = defaults.object(forKey: "threeFingerEnabled") as? Bool ?? true
        let stored = defaults.object(forKey: "debounceMilliseconds") as? Double ?? 40
        debounceMilliseconds = stored.isFinite ? min(max(stored, 0), 200) : 40
        showDebug = defaults.bool(forKey: "showDebug")
        defaults.removeObject(forKey: "showMenuBar")
        machine.debounce = debounceMilliseconds / 1000
    }

    var commandPressed: Bool { state == .commandPressed }
    var stateTitle: String {
        switch state {
        case .idle: "等待三指触摸"
        case .commandPressed: "模拟 ⌘ 已按住"
        case .disabled: "已停用"
        case .unavailable: "暂不可用"
        }
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let app = Self.shared
                    app.suspended = true
                    app.stop(as: app.enabled ? .unavailable : .disabled)
                    app.message = "休眠或会话暂停；恢复后重新连接触控板"
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    Self.shared.suspended = false
                    Self.shared.restart(wakeRetries: 5)
                }
            })
        }
        refreshLogin()
        restart()
    }

    func restart(wakeRetries: Int = 0) {
        guard started else { return }
        stop(as: .disabled)
        refreshPermissions()
        guard enabled, threeFingerEnabled else { message = "功能已停用"; return }
        guard !suspended else { return }
        guard accessibilityGranted, inputGranted, CGPreflightPostEventAccess() else {
            _ = machine.stop(.unavailable)
            syncState()
            message = "请在系统设置中为 TouchChord 开启辅助功能和输入监控，再点击重新连接"
            return
        }
        let session = generation
        do {
            let keyboard = ModifierKeyController()
            self.keyboard = keyboard
            keyboard.onFailure = { [weak self] message in self?.fail(message) }
            keyboard.onEmergency = { [weak self] in self?.emergencyRelease() }
            try keyboard.start()
            let monitor = try MultitouchBridge { frame in
                DispatchQueue.main.async {
                    let app = Self.shared
                    guard app.generation == session else { return }
                    app.receive(frame)
                }
            }
            self.monitor = monitor
            machine.enable()
            lastDeviceTimestamp = nil
            try monitor.start()
            syncState()
            message = "已连接内置触控板；请先抬起手指，再以三指轻触"
        } catch {
            fail(String(describing: error))
            if wakeRetries > 0 {
                let retryGeneration = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.generation == retryGeneration else { return }
                    self.restart(wakeRetries: wakeRetries - 1)
                }
            }
        }
    }

    private func receive(_ frame: TouchFrame?) {
        guard let frame, ProcessInfo.processInfo.systemUptime - frame.receivedAt < 0.5,
              lastDeviceTimestamp.map({ frame.timestamp >= $0 }) ?? true else {
            fail("触摸数据异常或中断，Command 已请求释放；请重新连接")
            return
        }
        lastDeviceTimestamp = frame.timestamp
        apply(machine.ingest(count: frame.count, at: frame.receivedAt))
        if machine.state == .unavailable { fail("触摸状态无效；请重新连接"); return }
        syncState()
    }

    private func apply(_ action: TouchStateMachine.Action?) {
        switch action {
        case .press:
            guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), CGPreflightListenEventAccess(),
                  keyboard?.tapIsEnabled == true else { fail("输入权限或监听已失效，功能已暂停"); return }
            keyboard?.pressCommand()
            pressedAt = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated { Self.shared.checkHeldState() }
            }
            watchdog = timer
            RunLoop.main.add(timer, forMode: .common)
        case .release:
            keyboard?.releaseCommand()
            watchdog?.invalidate()
            watchdog = nil
        case nil: break
        }
    }

    private func checkHeldState() {
        let now = ProcessInfo.processInfo.systemUptime
        if machine.checkFreshness(at: now) == .release {
            fail("触摸数据超过 500 ms 未更新，Command 已请求释放")
            return
        }
        guard keyboard?.tapIsEnabled == true, AXIsProcessTrusted(), CGPreflightPostEventAccess(),
              CGPreflightListenEventAccess() else { fail("权限或输入过滤器已失效"); return }
        if now - pressedAt > 0.25, keyboard?.pressObserved != true {
            fail("未观察到 Command 按下事件，已请求释放")
        }
    }

    func emergencyRelease() {
        _ = machine.emergencyRelease()
        keyboard?.forceRelease()
        watchdog?.invalidate()
        watchdog = nil
        syncState()
        message = "已请求释放模拟 Command；先减少到两指或以下才能再次触发"
    }

    private func fail(_ reason: String) {
        stop(as: .unavailable)
        message = reason
        NSLog("TriKey: %@", reason)
    }

    private func stop(as state: TouchStateMachine.State) {
        generation = UUID()
        _ = machine.stop(state)
        watchdog?.invalidate()
        watchdog = nil
        // 保留物理来源直到模拟按键清理完成，再注销触摸和硬件输入。
        keyboard?.forceRelease()
        monitor?.stop()
        monitor = nil
        keyboard?.stop()
        keyboard = nil
        syncState()
    }

    private func syncState() {
        if state != machine.state {
            state = machine.state
            if showDebug { NSLog("TriKey: state=%@", state.rawValue) }
        }
        if fingerCount != machine.count { fingerCount = machine.count }
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        inputGranted = CGPreflightListenEventAccess()
    }

    func requestAccessibility() {
        preparePermissionRequest()
        // SDK 将这个只读 C 常量导入为全局 var；使用核对过的键值，避免关闭 Swift 6 并发检查。
        let key = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openPrivacy("Privacy_Accessibility")
    }

    func requestInputMonitoring() {
        preparePermissionRequest()
        _ = CGRequestListenEventAccess()
        openPrivacy("Privacy_ListenEvent")
    }

    private func preparePermissionRequest() {
        // 系统可能要求退出应用；下次启动仍能继续本次授权流程。
        UserDefaults.standard.set(true, forKey: "resumePermissionSettings")
        SettingsPresenter.show(app: self)
    }

    func resumePermissionSettings() {
        guard started, UserDefaults.standard.bool(forKey: "resumePermissionSettings") else { return }
        refreshPermissions()
        if accessibilityGranted && inputGranted {
            UserDefaults.standard.removeObject(forKey: "resumePermissionSettings")
            restart()
        }
        SettingsPresenter.show(app: self)
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openMenuBarSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
        if !NSWorkspace.shared.open(url) {
            message = "无法打开系统设置，请手动进入系统设置 → 菜单栏。"
        }
    }

    func setLogin(_ enabled: Bool) {
        do { try LaunchAtLogin.setEnabled(enabled); refreshLogin() }
        catch { refreshLogin(); loginMessage = "登录启动设置失败：\(error.localizedDescription)" }
    }

    func refreshLogin() {
        loginEnabled = LaunchAtLogin.enabled
        loginMessage = LaunchAtLogin.statusText
    }

    func shutdown() {
        stop(as: .disabled)
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        started = false
    }
}
