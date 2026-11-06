import XCTest
@testable import TriKey

final class TouchStateMachineTests: XCTestCase {
    private func ready() -> TouchStateMachine {
        var state = TouchStateMachine()
        state.enable()
        _ = state.ingest(count: 0, at: 0)
        return state
    }

    func testExactCountsSwitchAndReleaseOutsideRange() {
        var state = ready()
        for (index, count) in [2, 3, 4, 3, 2].enumerated() {
            let time = Double(index + 1)
            XCTAssertEqual(state.ingest(count: count, at: time), index == 0 ? nil : .release)
            XCTAssertNil(state.ingest(count: count, at: time + 0.02))
            XCTAssertEqual(state.ingest(count: count, at: time + 0.05), .press(state.bindings[count]!))
            XCTAssertNil(state.ingest(count: count, at: time + 0.06))
        }
        XCTAssertEqual(state.ingest(count: 5, at: 6), .release)
        for (index, count) in [0, 1, 5, 6, 16].enumerated() {
            let time = Double(index + 7)
            XCTAssertNil(state.ingest(count: count, at: time))
            XCTAssertNil(state.ingest(count: count, at: time + 0.1))
        }
        XCTAssertNil(state.activeKey)
    }

    func testJitterDoesNotActivateAndReleaseHasNoDebounce() {
        var state = ready()
        _ = state.ingest(count: 3, at: 1)
        XCTAssertNil(state.ingest(count: 2, at: 1.02))
        XCTAssertNil(state.ingest(count: 3, at: 1.03))
        XCTAssertNil(state.ingest(count: 3, at: 1.06))
        XCTAssertEqual(state.ingest(count: 3, at: 1.08), .press(.command))
        XCTAssertEqual(state.ingest(count: 2, at: 1.081), .release)
    }

    func testEmergencyRequiresReleaseBeforeRearming() {
        var state = ready()
        _ = state.ingest(count: 3, at: 1)
        _ = state.ingest(count: 3, at: 1.1)
        XCTAssertEqual(state.emergencyRelease(), .release)
        XCTAssertNil(state.emergencyRelease())
        XCTAssertNil(state.ingest(count: 3, at: 2))
        XCTAssertNil(state.ingest(count: 2, at: 2.1))
        XCTAssertNil(state.ingest(count: 4, at: 2.2))
        XCTAssertNil(state.ingest(count: 1, at: 2.3))
        XCTAssertNil(state.ingest(count: 3, at: 2.4))
        XCTAssertNil(state.ingest(count: 3, at: 2.5))
        _ = state.ingest(count: 0, at: 3)
        _ = state.ingest(count: 3, at: 4)
        XCTAssertEqual(state.ingest(count: 3, at: 4.1), .press(.command))
    }

    func testStartupDoesNotArmFromExistingContact() {
        var state = TouchStateMachine()
        state.enable()
        XCTAssertNil(state.ingest(count: 3, at: 1))
        XCTAssertNil(state.ingest(count: 3, at: 2))
        XCTAssertEqual(state.state, .idle)
    }

    func testInterruptedStreamFailsClosedAndNeedsExplicitRestart() {
        var state = ready()
        _ = state.ingest(count: 3, at: 1)
        _ = state.ingest(count: 3, at: 1.1)
        XCTAssertEqual(state.checkFreshness(at: 1.7), .release)
        XCTAssertEqual(state.state, .unavailable)
        XCTAssertNil(state.ingest(count: 3, at: 2))
    }

    func testDisableAndInvalidInputReleaseExactlyOnce() {
        for stop in [TouchStateMachine.State.disabled, .unavailable] {
            var state = ready()
            _ = state.ingest(count: 3, at: 1)
            _ = state.ingest(count: 3, at: 1.1)
            XCTAssertEqual(state.stop(stop), .release)
            XCTAssertNil(state.stop(stop))
        }
        var state = ready()
        _ = state.ingest(count: 3, at: 1)
        _ = state.ingest(count: 3, at: 1.1)
        XCTAssertEqual(state.ingest(count: 99, at: 2), .release)
        XCTAssertEqual(state.state, .unavailable)
    }

    func testEveryCandidateAndDisabledBinding() {
        for key in TouchKey.modifiers {
            var state = ready()
            state.bindings = TouchBindings(two: key, three: nil, four: key)
            _ = state.ingest(count: 2, at: 1)
            XCTAssertEqual(state.ingest(count: 2, at: 1.1), .press(key))
            XCTAssertEqual(state.ingest(count: 3, at: 2), .release)
            XCTAssertNil(state.ingest(count: 3, at: 2.1))
            _ = state.ingest(count: 4, at: 3)
            XCTAssertEqual(state.ingest(count: 4, at: 3.1), .press(key))
            XCTAssertEqual(state.ingest(count: 0, at: 4), .release)
        }
    }

    func testSameKeyAcrossDifferentCountsStillDebounces() {
        var state = ready()
        state.bindings = TouchBindings(two: .command, three: .command, four: .command)
        _ = state.ingest(count: 2, at: 1)
        _ = state.ingest(count: 2, at: 1.1)
        XCTAssertEqual(state.ingest(count: 3, at: 2), .release)
        XCTAssertNil(state.ingest(count: 3, at: 2.02))
        XCTAssertEqual(state.ingest(count: 3, at: 2.05), .press(.command))
    }

    func testZeroDebounceDoesNotSkipReleaseOnSwitch() {
        var state = ready()
        state.debounce = 0
        XCTAssertEqual(state.ingest(count: 2, at: 1), .press(.control))
        XCTAssertEqual(state.ingest(count: 3, at: 2), .release)
        XCTAssertNil(state.activeKey)
        XCTAssertEqual(state.ingest(count: 3, at: 2.01), .press(.command))
    }

    func testInterruptedCandidateCannotActivateAfterRestart() {
        var state = ready()
        _ = state.ingest(count: 2, at: 1)
        _ = state.stop(.disabled)
        state.enable()
        XCTAssertNil(state.ingest(count: 2, at: 2))
        XCTAssertNil(state.ingest(count: 2, at: 3))
        _ = state.ingest(count: 0, at: 4)
        _ = state.ingest(count: 4, at: 5)
        XCTAssertEqual(state.ingest(count: 4, at: 5.1), .press(.option))
        XCTAssertEqual(state.ingest(count: 4, at: .nan), .release)
        XCTAssertEqual(state.state, .unavailable)
    }

    func testSingleKeysFireOncePerStableContactAndNeverHoldModifier() {
        for key in [TouchKey.returnKey, .escape] {
            var state = ready()
            state.bindings.two = key
            XCTAssertNil(state.ingest(count: 2, at: 1))
            XCTAssertEqual(state.ingest(count: 2, at: 1.1), .tap(key))
            XCTAssertEqual(state.state, .keyTriggered)
            for time in [1.2, 1.3, 2.0, 10.0] { XCTAssertNil(state.ingest(count: 2, at: time)) }
            XCTAssertEqual(state.ingest(count: 0, at: 11), .release)
            _ = state.ingest(count: 2, at: 12)
            XCTAssertEqual(state.ingest(count: 2, at: 12.1), .tap(key))
        }
    }

    func testSwitchFromModifierToSingleKeyReleasesFirst() {
        var state = ready()
        state.bindings.four = .escape
        _ = state.ingest(count: 3, at: 1)
        XCTAssertEqual(state.ingest(count: 3, at: 1.1), .press(.command))
        XCTAssertEqual(state.ingest(count: 4, at: 2), .release)
        XCTAssertNil(state.ingest(count: 4, at: 2.02))
        XCTAssertEqual(state.ingest(count: 4, at: 2.1), .tap(.escape))
        _ = state.emergencyRelease()
        XCTAssertNil(state.ingest(count: 4, at: 3))
        XCTAssertNil(state.ingest(count: 4, at: 4))
    }
}
