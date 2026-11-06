import Foundation

// 框架回调可能来自任意线程；文件、计数和摘要全部受同一把锁保护。
final class ProbeLog: @unchecked Sendable {
    static let shared = ProbeLog()
    private let lock = NSLock()
    private var file: FileHandle?
    private var frames = 0
    private var invalid = 0
    private var histogram: [Int: Int] = [:]
    private var previousStates: [Int32]?
    private var lastTimestamp: Double?
    private var maxFrameGap: Double = 0
    private var writeFailed = false
    private var injectionAttempted = false

    func open(_ path: String) throws {
        try lock.withLock {
            guard !FileManager.default.fileExists(atPath: path) else {
                throw ProbeError.unavailable("日志文件已存在，拒绝覆盖：\(path)")
            }
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw ProbeError.unavailable("无法创建日志：\(path)")
            }
            file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        }
    }

    func record(_ event: String, _ fields: [String: Any]) {
        lock.withLock {
            if event == "pulse_snapshot" || event == "virtual_command" { injectionAttempted = true }
            emit(event, fields)
        }
    }

    func invalidFrame() {
        DispatchQueue.main.async { HoldExperiment.current?.disarm("异常触摸帧") }
        lock.withLock {
            invalid += 1
            if invalid == 1 { emit("invalid_frame", ["result": "fail"]) }
        }
    }

    func frame(states: [Int32], timestamp: Double) {
        lock.withLock {
            frames += 1
            let touching = states.filter { $0 == 3 || $0 == 4 }.count
            histogram[touching, default: 0] += 1
            if let lastTimestamp {
                if timestamp < lastTimestamp { invalid += 1 }
                maxFrameGap = max(maxFrameGap, timestamp - lastTimestamp)
            }
            lastTimestamp = timestamp
            let sorted = states.sorted()
            if sorted != previousStates {
                emit("touch", ["rawCount": states.count, "touching": touching,
                               "states": sorted, "deviceTimestamp": timestamp])
                previousStates = sorted
            }
        }
    }

    func finish() -> Bool {
        lock.withLock {
            emit("summary", ["frames": frames, "invalidFrames": invalid,
                             "touchingHistogram": Dictionary(uniqueKeysWithValues: histogram.map { (String($0.key), $0.value) }),
                             "maxFrameGapSeconds": maxFrameGap,
                             "humanGroundTruthVerified": false,
                             "globalKeyInjectionAttempted": injectionAttempted])
            do { try file?.synchronize(); try file?.close() }
            catch { writeFailed = true }
            file = nil
            return !writeFailed && invalid == 0
        }
    }

    private func emit(_ event: String, _ fields: [String: Any]) {
        var record = fields
        record["event"] = event
        record["uptime"] = ProcessInfo.processInfo.systemUptime
        record["time"] = ISO8601DateFormatter().string(from: Date())
        do {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(0x0a)
            try FileHandle.standardOutput.write(contentsOf: data)
            try file?.write(contentsOf: data)
        } catch {
            writeFailed = true
            try? FileHandle.standardError.write(contentsOf: Data("日志写入失败：\(error)\n".utf8))
        }
    }
}
