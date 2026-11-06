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
    var pressedKeys: Set<TouchKey> {
        Set(TouchKey.allCases.filter { key in pressed.values.contains { !$0.isDisjoint(with: key.usages) } })
    }

    func start() throws {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6] as CFDictionary)
        IOHIDManagerSetInputValueMatchingMultiple(manager, ([0x28, 0x29] + Array(0xe0...0xe7)).map {
            [kIOHIDElementUsagePageKey: 7, kIOHIDElementUsageKey: $0]
        } as CFArray)
        Self.current = self
        IOHIDManagerRegisterInputValueCallback(manager, physicalValueCallback, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, physicalRemovalCallback, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let status = IOHIDManagerOpen(manager, 0)
        guard status == kIOReturnSuccess else {
            stop()
            throw HardwareError.unavailable("无法读取物理修饰键：IOHIDManagerOpen \(status)")
        }
        opened = true
        try refresh()
    }

    func refresh() throws {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            throw HardwareError.unavailable("没有可读取的物理键盘")
        }
        var snapshot: [UInt: Set<UInt32>] = [:]
        var foundUsages = Set<UInt32>()
        for device in devices {
            let id = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
            let elements = IOHIDDeviceCopyMatchingElements(device, [kIOHIDElementUsagePageKey: 7] as CFDictionary, 0) as? [IOHIDElement] ?? []
            for element in elements where TouchKey.allCases.contains(where: { $0.usages.contains(IOHIDElementGetUsage(element)) }) {
                foundUsages.insert(IOHIDElementGetUsage(element))
                let value = try withUnsafeTemporaryAllocation(of: Unmanaged<IOHIDValue>.self, capacity: 1) { buffer in
                    guard IOHIDDeviceGetValue(device, element, buffer.baseAddress!) == kIOReturnSuccess else {
                        throw HardwareError.unavailable("无法确认物理修饰键当前状态")
                    }
                    return IOHIDValueGetIntegerValue(buffer[0].takeUnretainedValue())
                }
                if value != 0 { snapshot[id, default: []].insert(IOHIDElementGetUsage(element)) }
            }
        }
        guard TouchKey.allCases.allSatisfy({ !foundUsages.isDisjoint(with: $0.usages) }) else {
            throw HardwareError.unavailable("键盘没有提供完整的修饰键输入元素")
        }
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
    guard IOHIDElementGetUsagePage(element) == 7,
          TouchKey.allCases.contains(where: { $0.usages.contains(usage) }) else { return }
    let id = UInt(bitPattern: Unmanaged.passUnretained(IOHIDElementGetDevice(element)).toOpaque())
    let down = IOHIDValueGetIntegerValue(value) != 0
    MainActor.assumeIsolated { PhysicalKeyboardMonitor.current?.update(id: id, usage: usage, down: down) }
}

private let physicalRemovalCallback: IOHIDDeviceCallback = { _, _, _, device in
    let id = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    MainActor.assumeIsolated { PhysicalKeyboardMonitor.current?.removed(id: id) }
}
