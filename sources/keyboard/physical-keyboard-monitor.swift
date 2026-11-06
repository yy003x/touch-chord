import Foundation
import IOKit.hid
import TriKeyHardware

@MainActor
final class PhysicalKeyboardMonitor {
    static weak var current: PhysicalKeyboardMonitor?
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    private var opened = false
    private var pressed: [UInt: Set<UInt32>] = [:]
    var onFailure: ((String) -> Void)?
    var onChange: (() -> Void)?
    var isCommandPressed: Bool { pressed.values.contains { !$0.isEmpty } }

    func start() throws {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6] as CFDictionary)
        IOHIDManagerSetInputValueMatchingMultiple(manager, [
            [kIOHIDElementUsagePageKey: 7, kIOHIDElementUsageKey: 0xe3],
            [kIOHIDElementUsagePageKey: 7, kIOHIDElementUsageKey: 0xe7]
        ] as CFArray)
        Self.current = self
        IOHIDManagerRegisterInputValueCallback(manager, physicalValueCallback, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, physicalRemovalCallback, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let status = IOHIDManagerOpen(manager, 0)
        guard status == kIOReturnSuccess else {
            stop()
            throw HardwareError.unavailable("无法读取物理 Command：IOHIDManagerOpen \(status)")
        }
        opened = true
        try refresh()
    }

    func refresh() throws {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            throw HardwareError.unavailable("没有可读取的物理键盘")
        }
        var snapshot: [UInt: Set<UInt32>] = [:]
        var commandElements = 0
        for device in devices {
            let id = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
            let elements = IOHIDDeviceCopyMatchingElements(device, [kIOHIDElementUsagePageKey: 7] as CFDictionary, 0) as? [IOHIDElement] ?? []
            for element in elements where [UInt32(0xe3), 0xe7].contains(IOHIDElementGetUsage(element)) {
                commandElements += 1
                let value = try withUnsafeTemporaryAllocation(of: Unmanaged<IOHIDValue>.self, capacity: 1) { buffer in
                    guard IOHIDDeviceGetValue(device, element, buffer.baseAddress!) == kIOReturnSuccess else {
                        throw HardwareError.unavailable("无法确认物理 Command 当前状态")
                    }
                    return IOHIDValueGetIntegerValue(buffer[0].takeUnretainedValue())
                }
                if value != 0 { snapshot[id, default: []].insert(IOHIDElementGetUsage(element)) }
            }
        }
        guard commandElements > 0 else { throw HardwareError.unavailable("键盘没有提供 Command 输入元素") }
        pressed = snapshot
    }

    func update(id: UInt, usage: UInt32, down: Bool) {
        guard opened else { return }
        if down { pressed[id, default: []].insert(usage) }
        else { pressed[id]?.remove(usage) }
        onChange?()
    }

    func removed(id: UInt) {
        pressed.removeValue(forKey: id)
        onFailure?("键盘设备已断开，功能已暂停；检查连接后重新启用")
    }

    func stop() {
        if Self.current === self { Self.current = nil }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        if opened { IOHIDManagerClose(manager, 0) }
        opened = false
        pressed.removeAll()
    }
}

private let physicalValueCallback: IOHIDValueCallback = { _, result, _, value in
    guard result == kIOReturnSuccess else {
        MainActor.assumeIsolated { PhysicalKeyboardMonitor.current?.onFailure?("物理按键监听发生错误：\(result)") }
        return
    }
    let element = IOHIDValueGetElement(value)
    let usage = IOHIDElementGetUsage(element)
    guard IOHIDElementGetUsagePage(element) == 7, usage == 0xe3 || usage == 0xe7 else { return }
    let id = UInt(bitPattern: Unmanaged.passUnretained(IOHIDElementGetDevice(element)).toOpaque())
    let down = IOHIDValueGetIntegerValue(value) != 0
    MainActor.assumeIsolated { PhysicalKeyboardMonitor.current?.update(id: id, usage: usage, down: down) }
}

private let physicalRemovalCallback: IOHIDDeviceCallback = { _, _, _, device in
    let id = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    MainActor.assumeIsolated { PhysicalKeyboardMonitor.current?.removed(id: id) }
}
