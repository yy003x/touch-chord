import Foundation

struct TouchStateMachine {
    enum State: String { case idle, commandPressed = "command_pressed", disabled, unavailable }
    enum Action: Equatable { case press, release }
    private(set) var state: State = .disabled
    private(set) var count = 0
    private var candidateSince: Double?
    private var lastFrame: Double?
    private var needsRelease = true
    var debounce: Double = 0.04

    mutating func enable() {
        state = .idle
        count = 0
        candidateSince = nil
        lastFrame = nil
        needsRelease = true
    }

    mutating func stop(_ target: State) -> Action? {
        let action: Action? = state == .commandPressed ? .release : nil
        state = target
        candidateSince = nil
        lastFrame = nil
        needsRelease = true
        count = 0
        return action
    }

    mutating func emergencyRelease() -> Action? {
        let action: Action? = state == .commandPressed ? .release : nil
        if state == .commandPressed { state = .idle }
        candidateSince = nil
        needsRelease = true
        return action
    }

    mutating func ingest(count: Int, at time: Double) -> Action? {
        guard state == .idle || state == .commandPressed else { return nil }
        guard (0...16).contains(count), time.isFinite,
              lastFrame.map({ time >= $0 }) ?? true else { return stop(.unavailable) }
        lastFrame = time
        self.count = count
        if count < 3 {
            needsRelease = false
            candidateSince = nil
            if state == .commandPressed { state = .idle; return .release }
            return nil
        }
        guard !needsRelease, state != .commandPressed else { return nil }
        if candidateSince == nil { candidateSince = time }
        if time - candidateSince! >= debounce {
            state = .commandPressed
            return .press
        }
        return nil
    }

    mutating func checkFreshness(at time: Double) -> Action? {
        guard state == .commandPressed, let lastFrame, time - lastFrame > 0.5 else { return nil }
        return stop(.unavailable)
    }
}
