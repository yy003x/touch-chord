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
    @Published var twoFingerKey: TouchKey? { didSet { saveBinding(twoFingerKey, count: 2) } }
    @Published var threeFingerKey: TouchKey? { didSet { saveBinding(threeFingerKey, count: 3) } }
    @Published var fourFingerKey: TouchKey? { didSet { saveBinding(fourFingerKey, count: 4) } }
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
    @Published private(set) var activeKey: TouchKey?
    @Published private(set) var tapClickStatus: TapClickStatus = .unknown
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
    private var lastPreferenceCheck = 0.0

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        func binding(_ count: Int, fallback: TouchKey?) -> TouchKey? {
            guard let value = defaults.string(forKey: "fingerBinding\(count)") else { return fallback }
            return TouchKey(rawValue: value)
        }
        twoFingerKey = binding(2, fallback: .control)
        threeFingerKey = binding(3, fallback: defaults.object(forKey: "threeFingerEnabled") as? Bool == false ? nil : .command)
        fourFingerKey = binding(4, fallback: .option)
        let stored = defaults.object(forKey: "debounceMilliseconds") as? Double ?? 40
        debounceMilliseconds = stored.isFinite ? min(max(stored, 0), 200) : 40
        showDebug = defaults.bool(forKey: "showDebug")
        defaults.removeObject(forKey: "showMenuBar")
        machine.debounce = debounceMilliseconds / 1000
    }

    private func saveBinding(_ key: TouchKey?, count: Int) {
        UserDefaults.standard.set(key?.rawValue ?? "none", forKey: "fingerBinding\(count)")
        restart()
    }

    var modifierPressed: Bool { state == .modifierPressed }
    var stateTitle: String {
        switch state {
        case .idle: "等待 2／3／4 指触摸"
        case .modifierPressed: "模拟 \(activeKey?.title ?? "修饰键") 已按住"
        case .keyTriggered: "已触发 \(activeKey?.title ?? "按键")"
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
        refreshTouchPreference()
        machine.bindings = TouchBindings(two: twoFingerKey, three: threeFingerKey, four: fourFingerKey)
        guard !suspended else { return }
        let touchEnabled = enabled && [twoFingerKey, threeFingerKey, fourFingerKey].contains(where: { $0 != nil })
        guard touchEnabled || ModifierKeyController.hasPendingRecovery else {
            message = "功能已停用，或全部档位设为不触发"; return
        }
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
            // 安全释放不受触摸激活条件限制，确认恢复后才检查设置门禁。
            keyboard.recoverPendingReleases { [weak self] in
                guard let self, self.generation == session else { return }
                self.startTouchMonitoring(session: session, wakeRetries: wakeRetries)
            }
        } catch {
            handleStartFailure(error, wakeRetries: wakeRetries)
        }
    }

    private func startTouchMonitoring(session: UUID, wakeRetries: Int) {
        guard enabled, [twoFingerKey, threeFingerKey, fourFingerKey].contains(where: { $0 != nil }) else {
            stop(as: .disabled)
            message = "功能已停用，或全部档位设为不触发"; return
        }
        refreshTouchPreference()
        guard tapClickStatus == .disabled else {
            fail("请先在系统设置 → 触控板 → 光标与点按中关闭“轻点来点按”，再重新连接。\(tapClickStatus.title)")
            return
        }
        do {
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
            message = "已连接内置触控板；先抬起全部手指，再以 2、3 或 4 指触摸"
        } catch {
            handleStartFailure(error, wakeRetries: wakeRetries)
        }
    }

    private func handleStartFailure(_ error: Error, wakeRetries: Int) {
        fail(String(describing: error))
        if wakeRetries > 0 {
            let retryGeneration = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.generation == retryGeneration else { return }
                self.restart(wakeRetries: wakeRetries - 1)
            }
        }
    }

    private func receive(_ frame: TouchFrame?) {
        guard let frame, ProcessInfo.processInfo.systemUptime - frame.receivedAt < 0.5,
              lastDeviceTimestamp.map({ frame.timestamp >= $0 }) ?? true else {
            fail("触摸数据异常或中断，修饰键已请求释放；请重新连接")
            return
        }
        lastDeviceTimestamp = frame.timestamp
        apply(machine.ingest(count: frame.count, at: frame.receivedAt))
        if machine.state == .unavailable { fail("触摸状态无效；请重新连接"); return }
        syncState()
    }

    private func apply(_ action: TouchStateMachine.Action?) {
        switch action {
        case .tap(let key):
            refreshTouchPreference()
            guard tapClickStatus == .disabled, AXIsProcessTrusted(), CGPreflightPostEventAccess(),
                  CGPreflightListenEventAccess(), let keyboard else {
                fail("触控板设置或输入权限不可用，已暂停"); return
            }
            do {
                let sent = try keyboard.tap(key)
                message = sent ? "已发送一次 \(key.title)；保持触摸不连发" : "物理 \(key.title) 正按住，已跳过本次触摸动作"
            } catch { fail(String(describing: error)) }
        case .press(let key):
            refreshTouchPreference()
            guard tapClickStatus == .disabled else { fail("轻点来点按未确认关闭，已暂停触摸修饰键"); return }
            guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), CGPreflightListenEventAccess(),
                  keyboard?.tapIsEnabled == true else { fail("输入权限或监听已失效，功能已暂停"); return }
            keyboard?.press(key)
            guard keyboard?.heldKey == key else { fail("无法按下 \(key.title)，已暂停"); return }
            pressedAt = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated { Self.shared.checkHeldState() }
            }
            watchdog = timer
            RunLoop.main.add(timer, forMode: .common)
        case .release:
            keyboard?.release()
            watchdog?.invalidate()
            watchdog = nil
        case nil: break
        }
    }

    private func checkHeldState() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPreferenceCheck >= 0.5 {
            refreshTouchPreference()
            guard tapClickStatus == .disabled else { fail("轻点来点按设置已变化，修饰键已请求释放"); return }
        }
        if machine.checkFreshness(at: now) == .release {
            fail("触摸数据超过 500 ms 未更新，修饰键已请求释放")
            return
        }
        guard keyboard?.tapIsEnabled == true, AXIsProcessTrusted(), CGPreflightPostEventAccess(),
              CGPreflightListenEventAccess() else { fail("权限或输入过滤器已失效"); return }
        if now - pressedAt > 0.25, keyboard?.pressObserved != true {
            fail("未观察到修饰键按下事件，已请求释放")
        }
    }

    func emergencyRelease() {
        _ = machine.emergencyRelease()
        keyboard?.forceRelease()
        watchdog?.invalidate()
        watchdog = nil
        syncState()
        message = "已请求释放模拟修饰键；先抬起全部手指才能再次触发"
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
        if activeKey != machine.activeKey { activeKey = machine.activeKey }
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

    func refreshTouchPreference() {
        tapClickStatus = TapClickStatus.read()
        lastPreferenceCheck = ProcessInfo.processInfo.systemUptime
    }

    func openTrackpadSettings() {
        // 先释放，避免操作系统设置时仍持有模拟修饰键。
        emergencyRelease()
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"),
           !NSWorkspace.shared.open(url) {
            message = "请手动打开系统设置 → 触控板 → 光标与点按"
        }
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
