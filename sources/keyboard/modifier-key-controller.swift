import ApplicationServices
import Foundation
import TriKeyHardware

struct ModifierOwnership {
    private(set) var heldKey: TouchKey?
    mutating func press(_ key: TouchKey) -> Bool {
        guard key.isModifier, heldKey == nil else { return false }
        heldKey = key
        return true
    }
    mutating func release(physical: Set<TouchKey>) -> TouchKey? {
        guard let key = heldKey else { return nil }
        heldKey = nil
        return physical.contains(key) ? nil : key
    }
    func effective(physical: Set<TouchKey>) -> Set<TouchKey> {
        physical.union(heldKey.map { [$0] } ?? [])
    }
    func eventFlags(base: CGEventFlags, physical: Set<TouchKey>, pending: Set<TouchKey>) -> CGEventFlags {
        // 清除本应用尚未确认释放的来源，再合并当前来源，避免快速切换或恢复时重新带回旧键。
        var flags = base
        for key in pending { flags.remove(key.flag) }
        for key in effective(physical: physical) { flags.insert(key.flag) }
        return flags
    }
    func postedEventFlags(for key: TouchKey, base: CGEventFlags, physical: Set<TouchKey>, pending: Set<TouchKey>) -> CGEventFlags {
        // 单次按键保留投递时的快照；只有修饰键状态同步事件跟随当前来源。
        key.isModifier ? eventFlags(base: base, physical: physical, pending: pending) : base
    }
}

@MainActor
final class ModifierKeyController {
    static weak var current: ModifierKeyController?
    private static let marker: Int64 = 0x5452494b4559
    private static let recoveryKey = "pendingModifierReleases"
    private let keyboard = PhysicalKeyboardMonitor()
    private var eventSource: CGEventSource?
    private var downs: [TouchKey: CGEvent] = [:]
    private var ups: [TouchKey: CGEvent] = [:]
    private var pending = Set<TouchKey>()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var ownership = ModifierOwnership()
    private var recoveryCompletion: (@MainActor @Sendable () -> Void)?
    private var recoveryTimeout: Timer?
    private(set) var pressObserved = false
    var onFailure: ((String) -> Void)?
    var onEmergency: (() -> Void)?
    var heldKey: TouchKey? { ownership.heldKey }

    static var hasPendingRecovery: Bool { !pendingReleases().isEmpty }

    private static func pendingReleases() -> Set<TouchKey> {
        var keys = Set((UserDefaults.standard.stringArray(forKey: recoveryKey) ?? []).compactMap(TouchKey.init(rawValue:)))
        if UserDefaults.standard.bool(forKey: "TriKeyPendingCommandRelease") { keys.insert(.command) }
        return keys
    }

    func start() throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), CGPreflightListenEventAccess() else {
            throw HardwareError.unavailable("需要辅助功能与输入监控权限，请授权 TouchChord 后重新启用")
        }
        guard let eventSource = CGEventSource(stateID: .combinedSessionState) else {
            throw HardwareError.unavailable("无法创建修饰键事件源")
        }
        self.eventSource = eventSource
        for key in TouchKey.allCases {
            guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: key.keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: eventSource, virtualKey: key.keyCode, keyDown: false) else {
                throw HardwareError.unavailable("无法创建 \(key.title) 事件")
            }
            down.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            up.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            downs[key] = down
            ups[key] = up
        }
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
    }

    func recoverPendingReleases(completion: @escaping @MainActor @Sendable () -> Void) {
        // 只恢复本应用记录的来源；保留旧版 Command 标记，便于回退到 v1.0.0。
        pending = Self.pendingReleases()
        recoveryCompletion = completion
        for key in pending {
            if !keyboard.pressedKeys.contains(key) { postRelease(key) }
            else { recordPending(key, false) }
        }
        finishRecoveryIfNeeded()
        guard recoveryCompletion != nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onFailure?("未确认遗留按键释放，已保留恢复记录；请重新连接")
            }
        }
        recoveryTimeout = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishRecoveryIfNeeded() {
        guard pending.isEmpty, let completion = recoveryCompletion else { return }
        recoveryCompletion = nil
        recoveryTimeout?.invalidate()
        recoveryTimeout = nil
        // 等当前释放事件通过过滤器，再允许关闭过滤器或开始触摸监听。
        DispatchQueue.main.async(execute: completion)
    }

    func press(_ key: TouchKey) {
        guard tapIsEnabled, let down = downs[key], ownership.press(key) else { return }
        pressObserved = false
        recordPending(key, true)
        down.flags = effectiveFlags().union(key.flag)
        down.post(tap: .cghidEventTap)
    }

    func tap(_ key: TouchKey) throws -> Bool {
        guard !key.isModifier, tapIsEnabled, heldKey == nil, let down = downs[key], let up = ups[key] else {
            throw HardwareError.unavailable("无法发送 \(key.title)")
        }
        try keyboard.refresh()
        // 同名物理键按住时跳过本次动作，避免虚拟 Up 打断物理按住状态。
        guard !keyboard.pressedKeys.contains(key) else { return false }
        recordPending(key, true)
        let flags = effectiveFlags()
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    func release() {
        guard let key = heldKey else { return }
        var failure: String?
        do { try keyboard.refresh() }
        catch { failure = "释放时无法确认物理按键状态，已按最近记录清理并暂停：\(error)" }
        if let released = ownership.release(physical: keyboard.pressedKeys) { postRelease(released) }
        else { recordPending(key, false) }
        pressObserved = false
        if let failure { onFailure?(failure) }
    }

    func forceRelease() {
        release()
    }

    var tapIsEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    private func effectiveFlags() -> CGEventFlags {
        ownership.eventFlags(base: CGEventSource.flagsState(.hidSystemState), physical: keyboard.pressedKeys, pending: pending)
    }

    private func postRelease(_ key: TouchKey) {
        guard let up = ups[key] else { return }
        var flags = effectiveFlags()
        flags.remove(key.flag)
        up.flags = flags
        up.post(tap: .cghidEventTap)
    }

    private func recordPending(_ key: TouchKey, _ value: Bool) {
        if value { pending.insert(key) } else { pending.remove(key) }
        UserDefaults.standard.set(pending.map(\.rawValue).sorted(), forKey: Self.recoveryKey)
        UserDefaults.standard.set(pending.contains(.command), forKey: "TriKeyPendingCommandRelease")
        // 每次真实状态转换同步一次小型恢复标记，不在触摸帧上执行磁盘写入。
        _ = UserDefaults.standard.synchronize()
    }

    func stop() {
        recoveryCompletion = nil
        recoveryTimeout?.invalidate()
        recoveryTimeout = nil
        forceRelease()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if Self.current === self { Self.current = nil }
        tap = nil
        runLoopSource = nil
        keyboard.stop()
        eventSource = nil
        downs.removeAll()
        ups.removeAll()
    }

    func filter(type: CGEventType, key: Int64, userData: Int64, pid: Int64, rawFlags: UInt64) -> (Bool, UInt64) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onFailure?("输入过滤器已被系统关闭，修饰键已请求释放；请重新启用")
            return (true, rawFlags)
        }
        var flags = CGEventFlags(rawValue: rawFlags)
        if userData == Self.marker && pid == Int64(getpid()) {
            guard let eventKey = TouchKey.allCases.first(where: { Int64($0.keyCode) == key }) else {
                return (true, rawFlags)
            }
            let effective = ownership.postedEventFlags(for: eventKey, base: flags,
                                                      physical: keyboard.pressedKeys, pending: pending)
            if eventKey.isModifier {
                if flags.contains(eventKey.flag), heldKey == eventKey { pressObserved = true }
                if !flags.contains(eventKey.flag), heldKey != eventKey { recordPending(eventKey, false) }
            } else if type == .keyUp {
                recordPending(eventKey, false)
            }
            finishRecoveryIfNeeded()
            if !eventKey.isModifier, type == .keyUp, keyboard.pressedKeys.contains(eventKey) {
                return (false, effective.rawValue)
            }
            return (true, effective.rawValue)
        }
        // Escape 仅在模拟修饰键活跃时用作紧急释放。
        if type == .keyDown, key == 53, heldKey != nil {
            onEmergency?()
            return (false, rawFlags)
        }
        if let heldKey { flags.insert(heldKey.flag) }
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
