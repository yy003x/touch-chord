import AppKit
import ApplicationServices

// 真实桌面回归：只操作 TouchChord 的设置按钮和系统设置的关闭按钮，不修改隐私授权。
let bundleID = "local.trikey.app"
let appURL = URL(fileURLWithPath: "/Applications/TouchChord.app")
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        let target = running(bundleID)
        let top = visibleWindows().first
        fputs("STATE frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown") " +
              "targetPID=\(target?.processIdentifier ?? -1) policy=\(target?.activationPolicy.rawValue ?? -1) " +
              "topOwner=\(top?[kCGWindowOwnerName as String] ?? "none") " +
              "targetWindows=\(target.map { windowIDs($0.processIdentifier) } ?? [])\n", stderr)
        exit(1)
    }
}
func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
}
func running(_ id: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: id).first
}
func windows(_ app: NSRunningApplication) -> [AXUIElement] {
    (value(AXUIElementCreateApplication(app.processIdentifier), "AXWindows") as? [AXUIElement] ?? [])
        .filter { value($0, "AXRole") as? String == "AXWindow" }
}
func settingsWindow(_ app: NSRunningApplication) -> AXUIElement? {
    windows(app).first { value($0, "AXTitle") as? String == "TouchChord 设置" }
}
func findButton(_ root: AXUIElement, _ title: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 10 else { return nil }
    if value(root, "AXRole") as? String == "AXButton", value(root, "AXDescription") as? String == title { return root }
    for child in value(root, "AXChildren") as? [AXUIElement] ?? [] {
        if let result = findButton(child, title, depth: depth + 1) { return result }
    }
    return nil
}
func wait(until predicate: () -> Bool, timeout: Double = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if predicate() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return predicate()
}
func visibleWindows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { $0[kCGWindowLayer as String] as? Int == 0 }
}
func windowIDs(_ pid: pid_t) -> [Int] {
    visibleWindows().filter { $0[kCGWindowOwnerPID as String] as? Int32 == pid }
        .compactMap { $0[kCGWindowNumber as String] as? Int }
}
func isFront(_ pid: pid_t) -> Bool {
    running(bundleID)?.processIdentifier == pid && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid &&
        visibleWindows().first?[kCGWindowOwnerPID as String] as? Int32 == pid
}
func close(_ window: AXUIElement) {
    guard let button = value(window, "AXCloseButton"), CFGetTypeID(button) == AXUIElementGetTypeID() else {
        require(false, "关闭按钮不可用"); return
    }
    require(AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString) == .success,
            "关闭按钮操作失败")
}
require(AXIsProcessTrusted(), "测试宿主缺少辅助功能权限")
require(NSWorkspace.shared.open(appURL), "无法打开已安装应用")
require(wait { running(bundleID).map { settingsWindow($0) != nil && isFront($0.processIdentifier) } ?? false }, "设置窗口未出现")
let app = running(bundleID)!
let pid = app.processIdentifier
let originalIDs = windowIDs(pid)
require(originalIDs.count == 1, "测试需要唯一可见的设置窗口")
require(app.activationPolicy == .regular, "设置打开时必须参与普通应用切换")

for round in 1...3 {
    for label in ["授权辅助功能…", "授权输入监控…"] {
        guard let window = settingsWindow(app), let button = findButton(window, label) else {
            require(false, "找不到授权入口"); exit(1)
        }
        require(AXUIElementPerformAction(button, kAXPressAction as CFString) == .success, "打开授权入口失败")
        require(wait {
            running("com.apple.systempreferences").map {
                !windows($0).isEmpty && NSWorkspace.shared.frontmostApplication?.processIdentifier == $0.processIdentifier
            } ?? false
        }, "系统设置未进入前台")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        require(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences", "打开授权后应用抢回焦点")
        close(windows(running("com.apple.systempreferences")!).first!)
        require(wait { isFront(pid) && windowIDs(pid) == originalIDs }, "系统窗口关闭后未回到原设置窗口")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        require(isFront(pid) && windowIDs(pid) == originalIDs, "设置窗口随后被遮挡或丢失")
        require(!app.isHidden && app.activationPolicy == .regular, "窗口策略或隐藏状态错误")
        print("PASS round=\(round) entry=\(label) pid=\(pid) window=\(originalIDs[0]) returnedToSettings=true")
        fflush(stdout)
    }
}
close(settingsWindow(app)!)
require(wait { running(bundleID)?.activationPolicy == .accessory && windowIDs(pid).isEmpty }, "关闭设置后未恢复纯菜单栏模式")
require(running(bundleID)?.processIdentifier == pid, "关闭设置导致应用退出")
print("PASS closeSettings: sameProcess=true policy=accessory visibleWindows=0")
require(NSWorkspace.shared.open(appURL), "重新打开应用失败")
require(wait { running(bundleID)?.activationPolicy == .regular && isFront(pid) && windowIDs(pid) == originalIDs }, "设置重开失败")
print("PASS reopenSettings: sameProcess=true sameWindow=true policy=regular")
