import AppKit
import ApplicationServices

// 本机验收：仅查找系统菜单栏设置中的 TriKey 项，不操作其它应用或隐私授权。
func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}
func children(_ element: AXUIElement) -> [AXUIElement] { value(element, "AXChildren") as? [AXUIElement] ?? [] }
func describe(_ element: AXUIElement) -> String {
    ["AXRole", "AXTitle", "AXDescription", "AXValue", "AXIdentifier"].map { "\($0)=\(value(element, $0).map(String.init(describing:)) ?? "")" }.joined(separator: " ")
}
guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else {
    print("System Settings not running"); exit(1)
}
let root = AXUIElementCreateApplication(settings.processIdentifier)
var checkbox: AXUIElement?
func find(_ element: AXUIElement, ancestors: [AXUIElement] = []) {
    guard ancestors.count < 25 else { return }
    let text = ["AXTitle", "AXDescription", "AXValue"].compactMap { value(element, $0) as? String }.joined(separator: " ")
    if text.contains("TriKey") || text.contains("TouchChord") {
        print("MATCH \(describe(element))")
        if let parent = ancestors.last {
            let siblings = children(parent)
            if let index = siblings.firstIndex(where: { CFEqual($0, element) }), index + 1 < siblings.count,
               value(siblings[index + 1], "AXRole") as? String == "AXCheckBox" {
                checkbox = siblings[index + 1]
                print("CHECKBOX \(describe(siblings[index + 1]))")
            }
        }
    }
    children(element).forEach { find($0, ancestors: ancestors + [element]) }
}
for window in value(root, "AXWindows") as? [AXUIElement] ?? [] {
    guard value(window, "AXRole") as? String == "AXWindow" else {
        print("Unexpected window role; skipped"); continue
    }
    print("WINDOW \(describe(window))")
    find(window)
}
if CommandLine.arguments.contains("--hide") || CommandLine.arguments.contains("--show") {
    guard let checkbox else { print("TriKey checkbox unavailable"); exit(1) }
    let desired = CommandLine.arguments.contains("--show")
    if (value(checkbox, "AXValue") as? NSNumber)?.boolValue != desired {
        let result = AXUIElementPerformAction(checkbox, kAXPressAction as CFString)
        guard result == .success else { print("toggle failed: \(result.rawValue)"); exit(1) }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }
    print("AFTER \(describe(checkbox))")
}
if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "local.trikey.app").first {
    print("TriKey pid=\(app.processIdentifier)")
} else { print("TriKey not running") }
