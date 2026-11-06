import ApplicationServices
import AppKit
import Foundation
import Darwin
import TriKeyHardware

enum ProbeError: Error, CustomStringConvertible {
    case unavailable(String)
    var description: String {
        switch self { case .unavailable(let message): return message }
    }
}

@main
@MainActor
enum TriKeyProbe {
    static func main() {
        do { try run() }
        catch {
            ProbeLog.shared.record("error", ["message": String(describing: error)])
            _ = ProbeLog.shared.finish()
            exit(1)
        }
    }

    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, ["touch", "keyboard", "pulse", "pulse-hid", "hold", "target", "surface"].contains(args[0]), let seconds = Double(args[1]),
              seconds.isFinite, (1...300).contains(seconds) else {
            throw ProbeError.unavailable("用法：TriKeyProbe <touch|keyboard|pulse> <1...300 秒> <新的 JSONL 日志路径>；pulse 会发送一对 Command 事件")
        }
        try ProbeLog.shared.open(args[2])
        ProbeLog.shared.record("environment", [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "accessibility": AXIsProcessTrusted(),
            "listenAccess": CGPreflightListenEventAccess(),
            "postAccess": CGPreflightPostEventAccess(),
            "durationSeconds": seconds,
            "mode": args[0] == "target" ? "targeted_command_a" :
                (args[0].hasPrefix("pulse") || args[0] == "hold" ? "global_command_\(args[0])" : "read_only_\(args[0])")
        ])
        let monitor = ["touch", "hold"].contains(args[0]) ? try MultitouchBridge { frame in
            guard let frame else { ProbeLog.shared.invalidFrame(); return }
            ProbeLog.shared.frame(states: frame.states, timestamp: frame.timestamp)
            DispatchQueue.main.async {
                HoldExperiment.current?.receive(count: frame.count, receivedAt: frame.receivedAt)
            }
        } : nil
        let keyboard = !["touch", "surface"].contains(args[0]) ? KeyboardProbe() : nil
        let hold = ["hold", "target", "surface"].contains(args[0]) ? try HoldExperiment() : nil
        defer { hold?.stop(); monitor?.stop(); keyboard?.stop() }
        try keyboard?.start()
        if args[0] == "surface" { hold?.startSurface() }
        else { try hold?.start() }
        try monitor?.start()
        if args[0] == "target" { hold?.verifyTextTarget() }
        if args[0].hasPrefix("pulse") {
            try CommandPulse.run(hid: args[0] == "pulse-hid")
            keyboard?.stop()
            guard ProbeLog.shared.finish() else { exit(1) }
            return
        }
        let loop = CFRunLoopGetCurrent()
        let end = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { endRun() }
        }
        RunLoop.current.add(end, forMode: .common)
        // 信号处理器只交给 DispatchSource，避免在异步信号上下文调用 Swift 清理。
        let sources = [SIGINT, SIGTERM].map { number -> any DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { endRun() } }
            source.resume()
            return source
        }
        if hold != nil { NSApplication.shared.run() }
        else { CFRunLoopRun() }
        withExtendedLifetime(loop) {}
        end.invalidate()
        sources.forEach { $0.cancel() }
        hold?.stop()
        monitor?.stop()
        keyboard?.stop()
        guard ProbeLog.shared.finish() else { exit(1) }
    }

    static func endRun() {
        if let app = NSApp, app.isRunning {
            app.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 0, data1: 0, data2: 0) {
                app.postEvent(event, atStart: false)
            }
        }
        CFRunLoopStop(CFRunLoopGetMain())
    }
}
