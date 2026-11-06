import AppKit
import ApplicationServices

// 排障工具：只观察 TriKey 窗口，按参数关闭系统设置窗口，不操作授权开关。
func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}
func snapshot(_ label: String) {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "local.trikey.app").first else {
        print("\(label): TriKey not running"); return
    }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    let windows = value(root, "AXWindows") as? [AXUIElement] ?? []
    print("\(label): pid=\(app.processIdentifier) hidden=\(app.isHidden) active=\(app.isActive) windows=\(windows.count)")
    for window in windows {
        print("title=\(value(window, "AXTitle") ?? "" as CFString) minimized=\(value(window, "AXMinimized") ?? "" as CFString)")
    }
    let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    print("frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")")
    for (index, window) in list.enumerated() where window[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier {
        print("windowID=\(window[kCGWindowNumber as String] ?? "") onscreen=\(window[kCGWindowIsOnscreen as String] ?? false) layer=\(window[kCGWindowLayer as String] ?? "") bounds=\(window[kCGWindowBounds as String] ?? "")")
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
        for covering in list.prefix(index) where covering[kCGWindowLayer as String] as? Int == 0 {
            guard let bounds = covering[kCGWindowBounds as String] as? [String: Any],
                  let other = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.intersects(other) else { continue }
            print("overlapAbove owner=\(covering[kCGWindowOwnerName as String] ?? "") bounds=\(other)")
        }
    }
    print("systemSettingsRunning=\(!NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").isEmpty)")
}
snapshot("before")
if let buttonName = CommandLine.arguments.contains("--open-accessibility") ? "授权辅助功能…" :
    (CommandLine.arguments.contains("--open-input-monitoring") ? "授权输入监控…" : nil) {
    func findButton(_ root: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 10 else { return nil }
        if value(root, "AXRole") as? String == "AXButton", value(root, "AXDescription") as? String == buttonName { return root }
        for child in value(root, "AXChildren") as? [AXUIElement] ?? [] {
            if let found = findButton(child, depth: depth + 1) { return found }
        }
        return nil
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "local.trikey.app").first,
          let windows = value(AXUIElementCreateApplication(app.processIdentifier), "AXWindows") as? [AXUIElement],
          let button = windows.compactMap({ findButton($0) }).first else {
        print("TriKey permission button unavailable"); exit(1)
    }
    print("openPrivacy=\(AXUIElementPerformAction(button, kAXPressAction as CFString).rawValue)")
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    snapshot("privacy opened")
}
if CommandLine.arguments.contains("--close-system-settings") {
    guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else {
        print("System Settings not running"); exit(1)
    }
    let root = AXUIElementCreateApplication(settings.processIdentifier)
    let windows = value(root, "AXWindows") as? [AXUIElement] ?? []
    guard let window = windows.first, let close = value(window, "AXCloseButton"), CFGetTypeID(close) == AXUIElementGetTypeID() else {
        print("System Settings close button unavailable"); exit(1)
    }
    let result = AXUIElementPerformAction(unsafeBitCast(close, to: AXUIElement.self), kAXPressAction as CFString)
    print("closeSystemSettings=\(result.rawValue)")
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    snapshot("after")
}
