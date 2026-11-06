import AppKit
import ApplicationServices

@MainActor
final class HoldExperiment {
    static var current: HoldExperiment?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var window: NSWindow?
    private var textView: NSTextView?
    private var selectionObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var localMonitor: Any?
    private let status = NSTextField(labelWithString: "等待触摸")
    private let eventSource: CGEventSource
    private let down: CGEvent
    private let up: CGEvent
    private var active = false
    private var armed = true
    private var candidateSince: Double?
    private var pressedAt = 0.0
    private var lastFrame = ProcessInfo.processInfo.systemUptime
    private var watchdog: Timer?
    private var sleepObserver: NSObjectProtocol?

    init() throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(),
              let eventSource = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 55, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 55, keyDown: false) else {
            throw ProbeError.unavailable("持续按键实验需要辅助功能和事件发送权限")
        }
        self.eventSource = eventSource
        self.down = down
        self.up = up
        down.setIntegerValueField(.eventSourceUserData, value: 0x5452494b4559)
        up.setIntegerValueField(.eventSourceUserData, value: 0x5452494b4559)
    }

    func start() throws {
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .leftMouseUp,
                    .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                    .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: holdEventCallback, userInfo: nil),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw ProbeError.unavailable("无法创建修饰键事件过滤器")
        }
        self.tap = tap
        self.source = source
        Self.current = self
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let current = Self.current, current.active else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if now - current.lastFrame > 0.5 { current.disarm("触摸数据中断") }
                if now - current.pressedAt > 30 { current.disarm("实验单次最长 30 秒") }
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { Self.current?.disarm("系统休眠") } }
        showWindow()
        ProbeLog.shared.record("hold_started", ["maxHoldSeconds": 30, "staleTimeoutSeconds": 0.5,
                                               "activationDebounceSeconds": 0.04])
    }

    func startSurface() {
        Self.current = self
        showWindow()
        window?.title = "TriKey — 应用验收文本区"
        window?.styleMask.insert(.closable)
        status.stringValue = "由菜单栏 TriKey 控制 Command；本窗口不监听触摸或发送按键"
        if let instruction = window?.contentView?.subviews.first as? NSTextField {
            instruction.stringValue = "在下方验证三指 + A / C / V 和点击。\n全部抬起后关闭窗口即可。正式应用没有实验的 30 秒保持上限。"
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            let names: [UInt16: String] = [0: "A", 8: "C", 9: "V"]
            if event.type != .keyDown || names[event.keyCode] != nil {
                ProbeLog.shared.record("app_input", ["input": event.type == .keyDown ? names[event.keyCode]! : "click",
                    "command": event.modifierFlags.contains(.command)])
            }
            return event
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: window, queue: .main) { _ in
            MainActor.assumeIsolated { TriKeyProbe.endRun() }
        }
        ProbeLog.shared.record("surface_started", ["injectsEvents": false, "monitorsTrackpad": false])
    }

    func receive(count: Int, receivedAt: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - receivedAt < 0.5 else { disarm("触摸数据积压"); return }
        lastFrame = now
        if count < 3 {
            candidateSince = nil
            release("触摸少于三指")
            armed = true
        } else if armed && !active {
            if let candidateSince, now - candidateSince >= 0.04 {
                active = true
                pressedAt = now
                var flags = CGEventSource.flagsState(.hidSystemState)
                flags.insert(.maskCommand)
                down.flags = flags
                down.post(tap: .cghidEventTap)
                ProbeLog.shared.record("virtual_command", ["down": true, "physical": PhysicalCommands.shared.isPressed])
            } else if candidateSince == nil { candidateSince = now }
        }
        status.stringValue = "触摸 \(count) 指 · 模拟 ⌘ \(active ? "按住" : "释放") · 物理 ⌘ \(PhysicalCommands.shared.isPressed ? "按住" : "释放")"
    }

    func release(_ reason: String) {
        guard active else { return }
        active = false
        // 物理键仍按下时，交由其真实释放事件清除状态，避免发送错误的 Command Up。
        let physical = PhysicalCommands.shared.isPressed
        if !physical {
            var flags = CGEventSource.flagsState(.hidSystemState)
            flags.remove(.maskCommand)
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
        ProbeLog.shared.record("virtual_command", ["down": false, "physical": physical,
                                                  "postedUp": !physical, "reason": reason])
    }

    func disarm(_ reason: String) {
        release(reason)
        armed = false
        candidateSince = nil
        status.stringValue = "已释放：\(reason)；先抬起手指再继续"
        ProbeLog.shared.record("hold_disarmed", ["reason": reason])
    }

    func filter(type: CGEventType, key: Int64, ownEvent: Bool, rawFlags: UInt64) -> (Bool, UInt64) {
        var flags = CGEventFlags(rawValue: rawFlags)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            disarm("事件过滤器被系统关闭")
            TriKeyProbe.endRun()
            return (true, rawFlags)
        }
        if ownEvent {
            return (true, rawFlags)
        }
        if type == .keyDown && key == 53 {
            disarm("Escape 紧急停止")
            TriKeyProbe.endRun()
            return (false, rawFlags)
        }
        if active { flags.insert(.maskCommand) }
        if type == .flagsChanged || type == .leftMouseDown ||
            (type == .keyDown && [Int64(0), 8, 9].contains(key)) {
            ProbeLog.shared.record("effective_event", ["type": type.rawValue,
                "virtualCommand": active, "physicalCommand": PhysicalCommands.shared.isPressed,
                "commandFlag": flags.contains(.maskCommand)])
        }
        return (true, flags.rawValue)
    }

    func stop() {
        guard tap != nil || window != nil else { return }
        disarm("实验停止")
        watchdog?.invalidate()
        watchdog = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
        window?.orderOut(nil)
        window = nil
        textView = nil
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        Self.current = nil
    }

    private func showWindow() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = edit
        menu.addItem(editItem)
        app.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 250),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "TriKey — Phase 1 技术验证"
        window.isReleasedWhenClosed = false
        let instruction = NSTextField(wrappingLabelWithString:
            "三指及以上触摸 = ⌘。可在下方测试 A / C / V 和点击。\n每次最多保持 30 秒，Escape 随时停止。此窗口不是正式应用。")
        instruction.frame = NSRect(x: 20, y: 170, width: 560, height: 60)
        status.frame = NSRect(x: 20, y: 135, width: 560, height: 25)
        let text = NSTextView(frame: NSRect(x: 20, y: 20, width: 560, height: 100))
        text.string = "TriKey 验证文本：三指保持接触时按 A，应选中全部文字。"
        text.isRichText = false
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: text, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let text = Self.current?.textView else { return }
                ProbeLog.shared.record("text_selection", ["length": text.selectedRange().length,
                    "textLength": (text.string as NSString).length])
            }
        }
        window.contentView?.addSubview(instruction)
        window.contentView?.addSubview(status)
        window.contentView?.addSubview(text)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        app.activate(ignoringOtherApps: true)
        self.window = window
        self.textView = text
    }

    func verifyTextTarget() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                ProbeLog.shared.record("target_check", ["passed": false, "reason": "event allocation"])
                TriKeyProbe.endRun()
                return
            }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.postToPid(getpid())
            up.postToPid(getpid())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let length = self.textView?.selectedRange().length ?? 0
                let total = (self.textView?.string as NSString?)?.length ?? 0
                ProbeLog.shared.record("target_check", ["passed": length > 0 && length == total,
                                                        "selected": length, "total": total])
                TriKeyProbe.endRun()
            }
        }
    }
}

private let holdEventCallback: CGEventTapCallBack = { _, type, event, _ in
    let key = event.getIntegerValueField(.keyboardEventKeycode)
    let own = event.getIntegerValueField(.eventSourceUserData) == 0x5452494b4559
    let rawFlags = event.flags.rawValue
    let (pass, flags) = MainActor.assumeIsolated {
        guard let current = HoldExperiment.current else { return (true, rawFlags) }
        return current.filter(type: type, key: key, ownEvent: own, rawFlags: rawFlags)
    }
    event.flags = CGEventFlags(rawValue: flags)
    return pass ? Unmanaged.passUnretained(event) : nil
}
