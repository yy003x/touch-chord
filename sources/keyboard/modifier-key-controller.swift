import ApplicationServices
import Foundation
import TriKeyHardware

struct CommandOwnership {
    private(set) var virtualPressed = false
    mutating func press() -> Bool {
        guard !virtualPressed else { return false }
        virtualPressed = true
        return true
    }
    mutating func release(physicalPressed: Bool) -> Bool {
        guard virtualPressed else { return false }
        virtualPressed = false
        return !physicalPressed
    }
    func effective(physicalPressed: Bool) -> Bool { virtualPressed || physicalPressed }
}

@MainActor
final class ModifierKeyController {
    static weak var current: ModifierKeyController?
    private static let marker: Int64 = 0x5452494b4559
    private static let recoveryKey = "TriKeyPendingCommandRelease"
    private let keyboard = PhysicalKeyboardMonitor()
    private var eventSource: CGEventSource?
    private var down: CGEvent?
    private var up: CGEvent?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var ownership = CommandOwnership()
    private(set) var pressObserved = false
    var onFailure: ((String) -> Void)?
    var onEmergency: (() -> Void)?
    var physicalCommandPressed: Bool { keyboard.isCommandPressed }

    func start() throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), CGPreflightListenEventAccess() else {
            throw HardwareError.unavailable("需要辅助功能与输入监控权限，请授权 TouchChord 后重新启用")
        }
        guard let eventSource = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 55, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 55, keyDown: false) else {
            throw HardwareError.unavailable("无法创建 Command 事件")
        }
        self.eventSource = eventSource
        self.down = down
        self.up = up
        down.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        keyboard.onFailure = { [weak self] message in self?.onFailure?(message) }
        try keyboard.start()
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: modifierEventCallback, userInfo: nil),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw HardwareError.unavailable("无法安装全局输入过滤器，请检查辅助功能权限")
        }
        self.tap = tap
        runLoopSource = source
        Self.current = self
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // 仅清理本应用记录的未完成释放，不无条件清除其它程序的 Command。
        if UserDefaults.standard.bool(forKey: Self.recoveryKey) {
            if !keyboard.isCommandPressed { postRelease() }
            else { recordPending(false) }
        }
    }

    func pressCommand() {
        guard tap != nil, let down, ownership.press() else { return }
        pressObserved = false
        recordPending(true)
        down.flags = CGEventSource.flagsState(.hidSystemState).union(.maskCommand)
        down.post(tap: .cghidEventTap)
    }

    func releaseCommand() {
        guard ownership.virtualPressed else { return }
        let shouldPost = ownership.release(physicalPressed: keyboard.isCommandPressed)
        if shouldPost { postRelease() }
        else { recordPending(false) }
        pressObserved = false
    }

    func forceRelease() {
        // 主动读取一次，降低遗漏释放回调的影响；读取失败时仍执行已有来源状态下的尽力清理。
        if isCommandPressed() {
            do { try keyboard.refresh() }
            catch { NSLog("TriKey: physical state refresh failed during release: %@", String(describing: error)) }
        }
        releaseCommand()
    }

    func isCommandPressed() -> Bool { ownership.virtualPressed }
    var tapIsEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    private func postRelease() {
        guard let up else { return }
        var flags = CGEventSource.flagsState(.hidSystemState)
        flags.remove(.maskCommand)
        up.flags = flags
        up.post(tap: .cghidEventTap)
    }

    private func recordPending(_ value: Bool) {
        guard UserDefaults.standard.bool(forKey: Self.recoveryKey) != value else { return }
        UserDefaults.standard.set(value, forKey: Self.recoveryKey)
        // 每次真实状态转换同步一次小型恢复标记，不在触摸帧上执行磁盘写入。
        _ = UserDefaults.standard.synchronize()
    }

    func stop() {
        forceRelease()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if Self.current === self { Self.current = nil }
        tap = nil
        runLoopSource = nil
        keyboard.stop()
        eventSource = nil
        down = nil
        up = nil
    }

    func filter(type: CGEventType, key: Int64, userData: Int64, pid: Int64, rawFlags: UInt64) -> (Bool, UInt64) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onFailure?("输入过滤器已被系统关闭，Command 已请求释放；请重新启用")
            return (true, rawFlags)
        }
        var flags = CGEventFlags(rawValue: rawFlags)
        if userData == Self.marker && pid == Int64(getpid()) {
            if flags.contains(.maskCommand), isCommandPressed() { pressObserved = true }
            if !flags.contains(.maskCommand), !isCommandPressed() { recordPending(false) }
            return (true, rawFlags)
        }
        // Escape 仅在模拟 Command 活跃时用作紧急释放；其它时候保持原有行为。
        if type == .keyDown, key == 53, isCommandPressed() {
            onEmergency?()
            return (false, rawFlags)
        }
        if isCommandPressed() { flags.insert(.maskCommand) }
        return (true, flags.rawValue)
    }
}

private let modifierEventCallback: CGEventTapCallBack = { _, type, event, _ in
    let key = event.getIntegerValueField(.keyboardEventKeycode)
    let userData = event.getIntegerValueField(.eventSourceUserData)
    let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
    let rawFlags = event.flags.rawValue
    let (pass, flags) = MainActor.assumeIsolated {
        guard let current = ModifierKeyController.current else { return (true, rawFlags) }
        return current.filter(type: type, key: key, userData: userData, pid: pid, rawFlags: rawFlags)
    }
    event.flags = CGEventFlags(rawValue: flags)
    return pass ? Unmanaged.passUnretained(event) : nil
}
