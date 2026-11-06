import AppKit
import ApplicationServices

// 真实设置界面回归：失败也恢复原映射，并核对界面和持久配置。
struct VerificationFailure: Error, CustomStringConvertible {
    let description: String
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VerificationFailure(description: message) }
}
func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}
func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 10 else { return [] }
    return [element] + (value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        .flatMap { descendants($0, depth: depth + 1) }
}
func settleUI() { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }

func run() throws {
    let domain = "local.trikey.app" as CFString
    let choices = [("Command ⌘", "command"), ("Option ⌥", "option"), ("Control ⌃", "control"),
                   ("Shift ⇧", "shift"), ("Return ↩", "returnKey"), ("Esc ⎋", "escape"), ("不触发", "none")]
    try require(AXIsProcessTrusted(), "测试宿主需要辅助功能权限")
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: domain as String).first else {
        throw VerificationFailure(description: "TouchChord 未运行")
    }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard let window = (value(root, kAXWindowsAttribute) as? [AXUIElement])?.first else {
        throw VerificationFailure(description: "请先打开 TouchChord 设置")
    }
    func picker(_ index: Int) throws -> AXUIElement {
        let pickers = descendants(window).filter { value($0, kAXRoleAttribute) as? String == kAXPopUpButtonRole }
        try require(pickers.count == 3 && pickers.indices.contains(index), "应有且仅有三个映射下拉框")
        return pickers[index]
    }
    func storedValue(_ index: Int) throws -> String? {
        try require(CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost), "无法同步持久配置")
        return CFPreferencesCopyValue("fingerBinding\(index + 2)" as CFString, domain,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }
    func verifyStored(_ index: Int, _ expected: String?) throws {
        let actual = try storedValue(index)
        try require(actual == expected, "\(index + 2) 指持久配置不符：expected=\(expected ?? "nil") actual=\(actual ?? "nil")")
    }
    func select(_ index: Int, _ title: String) throws {
        app.activate(options: [])
        settleUI()
        let element = try picker(index)
        func cancelMenus() {
            for menu in descendants(element) + descendants(window)
                where value(menu, kAXRoleAttribute) as? String == kAXMenuRole {
                _ = AXUIElementPerformAction(menu, "AXCancel" as CFString)
            }
        }
        // 失败时也收起菜单，避免下一档恢复被上一次展开的菜单阻挡。
        defer { cancelMenus() }
        if !descendants(element).contains(where: { value($0, kAXRoleAttribute) as? String == kAXMenuItemRole }) {
            try require(AXUIElementPerformAction(element, kAXPressAction as CFString) == .success, "无法打开下拉框")
        }
        settleUI()
        let items = descendants(element) + descendants(window)
        guard let item = items.first(where: {
            value($0, kAXRoleAttribute) as? String == kAXMenuItemRole &&
            (value($0, kAXTitleAttribute) as? String == title || value($0, kAXValueAttribute) as? String == title)
        }) else {
            throw VerificationFailure(description: "找不到候选项 \(title)")
        }
        try require(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success, "无法选择 \(title)")
        cancelMenus()
        settleUI()
        let refreshed = try picker(index)
        try require(value(refreshed, kAXValueAttribute) as? String == title, "选择后显示值不符")
    }
    if let argument = CommandLine.arguments.firstIndex(of: "--set") {
        try require(argument + 2 < CommandLine.arguments.count, "--set 需要手指数和按键")
        guard let count = Int(CommandLine.arguments[argument + 1]), (2...4).contains(count),
              let choice = choices.first(where: { $0.1 == CommandLine.arguments[argument + 2] }) else {
            throw VerificationFailure(description: "--set 需要 2/3/4 及 command/option/control/shift/returnKey/escape/none")
        }
        try select(count - 2, choice.0)
        try verifyStored(count - 2, choice.1)
        print("PASS selected fingers=\(count) value=\(choice.1)")
        return
    }

    // 所有快照必须在第一次写入前取得，包括原本未设置持久键的情况。
    let originals: [(title: String, stored: String?)] = try (0..<3).map { index in
        let element = try picker(index)
        guard let title = value(element, kAXValueAttribute) as? String,
              choices.contains(where: { $0.0 == title }) else {
            throw VerificationFailure(description: "无法读取 \(index + 2) 指原映射，未开始回归")
        }
        return (title, try storedValue(index))
    }
    func restore(_ indices: Set<Int>, to snapshots: [(title: String, stored: String?)]) -> [String] {
        var failures: [String] = []
        for index in indices.sorted() {
            let snapshot = snapshots[index]
            do { try select(index, snapshot.title) }
            catch { failures.append("\(index + 2) 指界面恢复失败：\(error)") }
            // 界面恢复用于同步应用内状态；同时还原原始持久值，避免把缺省值永久写成显式映射。
            CFPreferencesSetValue("fingerBinding\(index + 2)" as CFString, snapshot.stored as CFString?, domain,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            do { try verifyStored(index, snapshot.stored) }
            catch { failures.append("\(index + 2) 指持久配置恢复失败：\(error)") }
            do {
                let element = try picker(index)
                let actual = value(element, kAXValueAttribute) as? String
                try require(actual == snapshot.title, "expected=\(snapshot.title) actual=\(actual ?? "nil")")
            } catch { failures.append("\(index + 2) 指仍可能残留测试映射：\(error)") }
        }
        return failures
    }

    var touched = Set<Int>()
    var failures: [String] = []
    do {
        for index in originals.indices {
            // 选择操作可能已生效后才报错，必须在操作前登记恢复责任。
            touched.insert(index)
            for (title, stored) in choices {
                try select(index, title)
                try verifyStored(index, stored)
                print("PASS fingers=\(index + 2) selection=\(title) persisted=\(stored)")
                fflush(stdout)
            }
        }
        try require(NSRunningApplication.runningApplications(withBundleIdentifier: domain as String).first?.processIdentifier == app.processIdentifier,
                    "配置变更导致进程退出")
    } catch { failures.append(String(describing: error)) }

    // 所有正常错误都汇入清理路径；仅显式 --set 保持设置命令的写入语义。
    let defaults: [(title: String, stored: String?)] = [("Control ⌃", "control"), ("Command ⌘", "command"), ("Option ⌥", "option")]
    let restoreDefaults = failures.isEmpty && CommandLine.arguments.contains("--restore-defaults")
    let target = restoreDefaults ? defaults : originals
    let restorationFailures = restore(touched, to: target)
    failures.append(contentsOf: restorationFailures)
    var originalsRestored = !restoreDefaults && restorationFailures.isEmpty
    if restoreDefaults && !restorationFailures.isEmpty {
        // 默认映射应用失败也回到运行前的快照。
        let rollbackFailures = restore(touched, to: originals)
        failures.append(contentsOf: rollbackFailures)
        originalsRestored = rollbackFailures.isEmpty
    }
    if !failures.isEmpty {
        if originalsRestored { print("RESTORED original mappings and persistent values") }
        else { failures.append("恢复未完整确认，可能残留配置；原始快照：\(originals)") }
        throw VerificationFailure(description: failures.joined(separator: "\n"))
    }
    print("PASS restored=\(target.map(\.title)) sameProcess=true")
}

do { try run() }
catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
