import Foundation
import Darwin

// 社区逆向的私有 ABI；不是 Apple SDK 契约。只在当前设备完成实测后才能用于产品。
struct MTVector {
    var x: Float
    var y: Float
    var vx: Float
    var vy: Float
}

struct MTContact {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalized: MTVector
    var size: Float
    var unknown1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTVector
    var unknown2: Int32
    var unknown3: Int32
    var density: Float

    static func isTouching(_ state: Int32) -> Bool { state == 3 || state == 4 }
    static var layoutMatches: Bool {
        MemoryLayout<Self>.stride == 96 &&
        MemoryLayout<Self>.offset(of: \.timestamp) == 8 &&
        MemoryLayout<Self>.offset(of: \.state) == 20 &&
        MemoryLayout<Self>.offset(of: \.normalized) == 32
    }
}

public enum HardwareError: Error, CustomStringConvertible {
    case unavailable(String)
    public var description: String {
        switch self { case .unavailable(let message): return message }
    }
}

public struct TouchFrame: Sendable {
    public let states: [Int32]
    public let timestamp: Double
    public let receivedAt: Double
    public var count: Int { states.filter(MTContact.isTouching).count }
}

private final class TouchCallbackRoute: @unchecked Sendable {
    static let shared = TouchCallbackRoute()
    private let lock = NSLock()
    private var receiver: (@Sendable (TouchFrame?) -> Void)?
    func install(_ receiver: (@Sendable (TouchFrame?) -> Void)?) {
        lock.withLock { self.receiver = receiver }
    }
    func send(_ frame: TouchFrame?) {
        let receiver = lock.withLock { self.receiver }
        receiver?(frame)
    }
}

typealias MTCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32
) -> Int32

private let contactCallback: MTCallback = { _, buffer, count, timestamp, _ in
    guard (0...16).contains(count), timestamp.isFinite, count == 0 || buffer != nil else {
        TouchCallbackRoute.shared.send(nil)
        return 0
    }
    // 数据只在回调期间有效；立即复制状态，不把框架指针交给其它线程。
    var states: [Int32] = []
    if let buffer {
        for index in 0..<Int(count) {
            let contact = buffer.loadUnaligned(
                fromByteOffset: index * MemoryLayout<MTContact>.stride, as: MTContact.self
            )
            guard (0...7).contains(contact.state), contact.timestamp.isFinite,
                  contact.normalized.x.isFinite, contact.normalized.y.isFinite else {
                TouchCallbackRoute.shared.send(nil)
                return 0
            }
            states.append(contact.state)
        }
    }
    TouchCallbackRoute.shared.send(TouchFrame(states: states, timestamp: timestamp,
                                            receivedAt: ProcessInfo.processInfo.systemUptime))
    return 0
}

public final class MultitouchBridge {
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Predicate = @convention(c) (UnsafeMutableRawPointer) -> Bool
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void

    private let handle: UnsafeMutableRawPointer
    private let devices: CFArray
    private let selected: UnsafeMutableRawPointer
    private let register: Register
    private let unregister: Register
    private let startDevice: Start
    private let stopDevice: Stop
    private let isRunning: Predicate
    private var started = false
    private let receiver: @Sendable (TouchFrame?) -> Void

    public init(receiver: @escaping @Sendable (TouchFrame?) -> Void) throws {
        self.receiver = receiver
        guard MTContact.layoutMatches else { throw HardwareError.unavailable("私有触点布局不匹配") }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw HardwareError.unavailable("无法加载 MultitouchSupport.framework")
        }
        do {
            func symbol<T>(_ name: String, as: T.Type) throws -> T {
                guard let value = dlsym(handle, name) else {
                    throw HardwareError.unavailable("缺少私有符号：\(name)")
                }
                return unsafeBitCast(value, to: T.self)
            }
            let create = try symbol("MTDeviceCreateList", as: CreateList.self)
            let builtIn = try symbol("MTDeviceIsBuiltIn", as: Predicate.self)
            register = try symbol("MTRegisterContactFrameCallback", as: Register.self)
            unregister = try symbol("MTUnregisterContactFrameCallback", as: Register.self)
            startDevice = try symbol("MTDeviceStart", as: Start.self)
            stopDevice = try symbol("MTDeviceStop", as: Stop.self)
            isRunning = try symbol("MTDeviceIsRunning", as: Predicate.self)
            guard let list = create()?.takeRetainedValue() else {
                throw HardwareError.unavailable("设备枚举返回空值")
            }
            var internalDevices: [UnsafeMutableRawPointer] = []
            for index in 0..<CFArrayGetCount(list) {
                guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
                let device = UnsafeMutableRawPointer(mutating: raw)
                if builtIn(device) { internalDevices.append(device) }
            }
            guard internalDevices.count == 1, let selected = internalDevices.first else {
                throw HardwareError.unavailable("预期一个内置设备，实际 \(internalDevices.count) 个；不猜测默认设备")
            }
            self.handle = handle
            self.devices = list
            self.selected = selected
        } catch {
            dlclose(handle)
            throw error
        }
    }

    public func start() throws {
        guard !started else { return }
        TouchCallbackRoute.shared.install(receiver)
        register(selected, contactCallback)
        startDevice(selected, 0)
        started = true
        guard isRunning(selected) else {
            stop()
            throw HardwareError.unavailable("触控设备启动后未报告 running")
        }
    }

    public func stop() {
        guard started else { return }
        TouchCallbackRoute.shared.install(nil)
        unregister(selected, contactCallback)
        stopDevice(selected)
        started = false
    }

    deinit {
        stop()
        // 私有框架不承诺注销后的回调排空时机；进程退出前保留动态库映射。
        _ = handle
        withExtendedLifetime(devices) {}
    }
}
