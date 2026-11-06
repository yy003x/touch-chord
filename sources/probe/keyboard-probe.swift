import ApplicationServices
import Foundation
import IOKit.hid

final class PhysicalCommands: @unchecked Sendable {
    static let shared = PhysicalCommands()
    private let lock = NSLock()
    private var down: [UInt: Set<UInt32>] = [:]

    func update(_ element: IOHIDElement, pressed: Bool) {
        let device = IOHIDElementGetDevice(element)
        let identity = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
        lock.withLock {
            let usage = IOHIDElementGetUsage(element)
            if pressed { down[identity, default: []].insert(usage) }
            else { down[identity]?.remove(usage) }
        }
    }

    var isPressed: Bool { lock.withLock { down.values.contains { !$0.isEmpty } } }
}

private let hidCommandCallback: IOHIDValueCallback = { _, result, _, value in
    guard result == kIOReturnSuccess else {
        ProbeLog.shared.record("hid_error", ["status": result])
        return
    }
    let element = IOHIDValueGetElement(value)
    let usage = IOHIDElementGetUsage(element)
    guard IOHIDElementGetUsagePage(element) == 7, usage == 0xe3 || usage == 0xe7 else { return }
    PhysicalCommands.shared.update(element, pressed: IOHIDValueGetIntegerValue(value) != 0)
    ProbeLog.shared.record("physical_command", [
        "side": usage == 0xe3 ? "left" : "right",
        "down": IOHIDValueGetIntegerValue(value) != 0,
        "hidLeft": CGEventSource.keyState(.hidSystemState, key: 55),
        "hidRight": CGEventSource.keyState(.hidSystemState, key: 54)
    ])
}

private let commandTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        ProbeLog.shared.record("event_tap_disabled", ["type": type.rawValue])
        MainActor.assumeIsolated { TriKeyProbe.endRun() }
        return Unmanaged.passUnretained(event)
    }
    let key = event.getIntegerValueField(.keyboardEventKeycode)
    if key == 54 || key == 55 {
        ProbeLog.shared.record("command_event", [
            "eventType": type.rawValue,
            "probeEvent": event.getIntegerValueField(.eventSourceUserData) == 0x5452494b4559,
            "side": key == 55 ? "left" : "right", "commandFlag": event.flags.contains(.maskCommand),
            "hidLeft": CGEventSource.keyState(.hidSystemState, key: 55),
            "hidRight": CGEventSource.keyState(.hidSystemState, key: 54),
            "sessionLeft": CGEventSource.keyState(.combinedSessionState, key: 55),
            "sessionRight": CGEventSource.keyState(.combinedSessionState, key: 54)
        ])
    }
    return Unmanaged.passUnretained(event)
}

final class KeyboardProbe {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var opened = false

    func start() throws {
        guard CGPreflightListenEventAccess() else {
            throw ProbeError.unavailable("缺少输入监控权限：系统设置 → 隐私与安全性 → 输入监控，授权运行探针的宿主后重新启动")
        }
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6
        ] as CFDictionary)
        IOHIDManagerSetInputValueMatchingMultiple(manager, [
            [kIOHIDElementUsagePageKey: 7, kIOHIDElementUsageKey: 0xe3],
            [kIOHIDElementUsagePageKey: 7, kIOHIDElementUsageKey: 0xe7]
        ] as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, hidCommandCallback, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            throw ProbeError.unavailable("IOHIDManagerOpen 失败：\(status)")
        }
        opened = true
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        let deviceCount = devices.count
        guard deviceCount > 0 else { throw ProbeError.unavailable("没有可读取的 HID 键盘") }
        for device in devices {
            let elements = IOHIDDeviceCopyMatchingElements(device, [kIOHIDElementUsagePageKey: 7] as CFDictionary, 0) as? [IOHIDElement] ?? []
            for element in elements where [UInt32(0xe3), 0xe7].contains(IOHIDElementGetUsage(element)) {
                let value = try withUnsafeTemporaryAllocation(of: Unmanaged<IOHIDValue>.self, capacity: 1) { buffer in
                    guard IOHIDDeviceGetValue(device, element, buffer.baseAddress!) == kIOReturnSuccess else {
                        throw ProbeError.unavailable("无法读取物理 Command 初始状态")
                    }
                    return buffer[0].takeUnretainedValue()
                }
                PhysicalCommands.shared.update(element, pressed: IOHIDValueGetIntegerValue(value) != 0)
            }
        }
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .listenOnly, eventsOfInterest: mask,
                                         callback: commandTapCallback, userInfo: nil),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw ProbeError.unavailable("无法创建只读 Command 事件监听")
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        ProbeLog.shared.record("keyboard_started", ["devices": deviceCount,
            "hidLeft": CGEventSource.keyState(.hidSystemState, key: 55),
            "hidRight": CGEventSource.keyState(.hidSystemState, key: 54)])
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
        if opened {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            opened = false
            ProbeLog.shared.record("keyboard_stopped", [:])
        }
    }

    deinit { stop() }
}

enum CommandPulse {
    static func run(hid: Bool) throws {
        guard CGPreflightPostEventAccess(), AXIsProcessTrusted() else {
            throw ProbeError.unavailable("模拟按键需要辅助功能授权")
        }
        guard !PhysicalCommands.shared.isPressed,
              !CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) else {
            throw ProbeError.unavailable("Command 已按下，跳过短脉冲测试")
        }
        guard let source = CGEventSource(stateID: hid ? .combinedSessionState : .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else {
            throw ProbeError.unavailable("无法创建成对的 Command 事件")
        }
        down.setIntegerValueField(.eventSourceUserData, value: 0x5452494b4559)
        up.setIntegerValueField(.eventSourceUserData, value: 0x5452494b4559)
        let location: CGEventTapLocation = hid ? .cghidEventTap : .cgSessionEventTap
        ProbeLog.shared.record("pulse_strategy", ["source": hid ? "combinedSessionState" : "privateState",
                                                  "location": hid ? "hid" : "session"])
        snapshot("before")
        // 只做有界实验，不将它视为已验证的持续修饰键控制器。
        down.flags = CGEventSource.flagsState(.hidSystemState).union(.maskCommand)
        down.post(tap: location)
        defer {
            var flags = CGEventSource.flagsState(.hidSystemState)
            if PhysicalCommands.shared.isPressed { flags.insert(.maskCommand) }
            else { flags.remove(.maskCommand) }
            up.flags = flags
            up.post(tap: location)
            CFRunLoopRunInMode(.defaultMode, 0.2, false)
            snapshot("after_release")
        }
        CFRunLoopRunInMode(.defaultMode, 0.2, false)
        snapshot("after_press")
    }

    private static func snapshot(_ stage: String) {
        ProbeLog.shared.record("pulse_snapshot", [
            "stage": stage, "physicalCommand": PhysicalCommands.shared.isPressed,
            "hidCommandFlag": CGEventSource.flagsState(.hidSystemState).contains(.maskCommand),
            "sessionCommandFlag": CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand),
            "sessionKeyState": CGEventSource.keyState(.combinedSessionState, key: 55)
        ])
    }
}
