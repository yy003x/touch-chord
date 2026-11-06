import AppKit
import ApplicationServices

// 一次性验收工具：仅访问 TriKey 的辅助功能树，不读取其它应用。
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "local.trikey.app").first else {
    print("TriKey is not running")
    exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, "AXChildren") as? [AXUIElement] ?? []
}
if CommandLine.arguments.contains("--watch-icon") {
    let deadline = Date().addingTimeInterval(45)
    var previous = ""
    while Date() < deadline {
        if let extras = attribute(root, "AXExtrasMenuBar"), CFGetTypeID(extras) == AXUIElementGetTypeID(),
           let item = children(unsafeBitCast(extras, to: AXUIElement.self)).first,
           let rawSize = attribute(item, "AXSize"), CFGetTypeID(rawSize) == AXValueGetTypeID() {
            var size = CGSize.zero
            AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size)
            let state = "\(attribute(item, "AXTitle") ?? "" as CFString) width=\(size.width) height=\(size.height)"
            if state != previous { print(state); fflush(stdout); previous = state }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    exit(0)
}
func walk(_ element: AXUIElement, depth: Int = 0) {
    guard depth <= 7 else { return }
    let role = attribute(element, "AXRole") as? String ?? ""
    let title = attribute(element, "AXTitle") as? String ?? ""
    let value = attribute(element, "AXValue").map { String(describing: $0) } ?? ""
    let description = attribute(element, "AXDescription") as? String ?? ""
    print("\(depth) \(role) title=\(title) value=\(value) description=\(description)")
    children(element).prefix(100).forEach { walk($0, depth: depth + 1) }
}
if CommandLine.arguments.contains("--open-menu"), let extras = attribute(root, "AXExtrasMenuBar"), CFGetTypeID(extras) == AXUIElementGetTypeID() {
    let menu = unsafeBitCast(extras, to: AXUIElement.self)
    if let item = children(menu).first {
        print("openMenu=\(AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
}
func find(_ element: AXUIElement, title: String, depth: Int = 0) -> AXUIElement? {
    guard depth <= 5 else { return nil }
    if attribute(element, "AXTitle") as? String == title { return element }
    for child in children(element) {
        if let found = find(child, title: title, depth: depth + 1) { return found }
    }
    return nil
}
// 不遍历系统 Apple 菜单及最近使用项目，只检查本应用的状态菜单和窗口。
if let value = attribute(root, "AXExtrasMenuBar"), CFGetTypeID(value) == AXUIElementGetTypeID() {
    let extras = unsafeBitCast(value, to: AXUIElement.self)
    if let index = CommandLine.arguments.firstIndex(of: "--press"), index + 1 < CommandLine.arguments.count {
        let title = CommandLine.arguments[index + 1]
        guard ["设置…", "重新连接", "启用", "紧急释放 ⌘", "退出 TriKey", "退出 TouchChord", "登录时启动", "系统菜单栏设置…"].contains(title),
              let item = find(extras, title: title) else { print("Action not found or not allowed"); exit(1) }
        print("press=\(AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    walk(extras)
}
let windows = attribute(root, "AXWindows") as? [AXUIElement] ?? []
print("windowCount=\(windows.count)")
windows.forEach {
    if attribute($0, "AXRole") as? String == "AXWindow" { walk($0) }
    else { print("Unexpected window role; skipped") }
}
