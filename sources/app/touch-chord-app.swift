import SwiftUI
import AppKit
import Darwin

@main
struct TriKeyApp: App {
    @NSApplicationDelegateAdaptor(TriKeyDelegate.self) private var delegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(app: app)
        } label: {
            Image(nsImage: app.commandPressed ? MenuBarIcon.pressed : MenuBarIcon.idle)
                .accessibilityLabel("TouchChord · \(app.stateTitle)")
        }
    }
}

@MainActor
final class TriKeyDelegate: NSObject, NSApplicationDelegate {
    private var signals: [any DispatchSourceSignal] = []
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil)
            return
        }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signals.append(source)
        }
        AppState.shared.start()
        AppState.shared.resumePermissionSettings()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppState.shared.resumePermissionSettings()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateNow }
        terminating = true
        AppState.shared.shutdown()
        // 给已排入系统的释放事件留出一次事件循环机会；不等同于投递保证。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsPresenter.show(app: AppState.shared)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
        signals.forEach { $0.cancel() }
    }
}
