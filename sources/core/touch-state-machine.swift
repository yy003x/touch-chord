import Foundation

struct TouchStateMachine {
    enum State: String { case idle, modifierPressed = "modifier_pressed", keyTriggered = "key_triggered", disabled, unavailable }
    enum Action: Equatable { case press(TouchKey), tap(TouchKey), release }
    private(set) var state: State = .disabled
    private(set) var count = 0
    private(set) var activeKey: TouchKey?
    var bindings = TouchBindings()
    private var candidateSince: Double?
    private var lastFrame: Double?
    private var needsRelease = true
    var debounce: Double = 0.04

    mutating func enable() {
        state = .idle
        activeKey = nil
        count = 0
        candidateSince = nil
        lastFrame = nil
        needsRelease = true
    }

    mutating func stop(_ target: State) -> Action? {
        let action: Action? = activeKey != nil ? .release : nil
        activeKey = nil
        state = target
        candidateSince = nil
        lastFrame = nil
        needsRelease = true
        count = 0
        return action
    }

    mutating func emergencyRelease() -> Action? {
        let action: Action? = activeKey != nil ? .release : nil
        activeKey = nil
        if state == .modifierPressed || state == .keyTriggered { state = .idle }
        candidateSince = nil
        needsRelease = true
        return action
    }

    mutating func ingest(count: Int, at time: Double) -> Action? {
        guard state == .idle || state == .modifierPressed || state == .keyTriggered else { return nil }
        guard (0...16).contains(count), time.isFinite,
              lastFrame.map({ time >= $0 }) ?? true else { return stop(.unavailable) }
        lastFrame = time
        let changed = self.count != count
        self.count = count
        // 启动和紧急释放后必须全部抬起，避免经过其它档位时意外重新触发。
        if count == 0 { needsRelease = false }
        let target = bindings[count]
        if changed || target != activeKey && activeKey != nil {
            candidateSince = nil
            if activeKey != nil {
                activeKey = nil
                state = .idle
                if target != nil, !needsRelease { candidateSince = time }
                return .release
            }
        }
        guard let target else {
            candidateSince = nil
            return nil
        }
        guard !needsRelease, activeKey == nil else { return nil }
        if candidateSince == nil { candidateSince = time }
        if time - candidateSince! >= debounce {
            state = target.isModifier ? .modifierPressed : .keyTriggered
            activeKey = target
            return target.isModifier ? .press(target) : .tap(target)
        }
        return nil
    }

    mutating func checkFreshness(at time: Double) -> Action? {
        guard state == .modifierPressed, let lastFrame, time - lastFrame > 0.5 else { return nil }
        return stop(.unavailable)
    }
}
