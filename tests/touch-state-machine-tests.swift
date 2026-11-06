import XCTest
@testable import TriKey

final class TouchStateMachineTests: XCTestCase {
    private func ready() -> TouchStateMachine {
        var state = TouchStateMachine()
        state.enable()
        _ = state.ingest(count: 0, at: 0)
        return state
    }

    func testThresholdAndContinuousFourToThree() {
        var state = ready()
        XCTAssertNil(state.ingest(count: 2, at: 1))
        XCTAssertNil(state.ingest(count: 3, at: 2))
        XCTAssertEqual(state.ingest(count: 3, at: 2.05), .press)
        XCTAssertNil(state.ingest(count: 4, at: 3))
        XCTAssertNil(state.ingest(count: 3, at: 4))
        XCTAssertEqual(state.ingest(count: 2, at: 5), .release)
        XCTAssertNil(state.ingest(count: 0, at: 6))
    }

    func testJitterDoesNotActivateAndReleaseHasNoDebounce() {
        var state = ready()
        _ = state.ingest(count: 3, at: 1)
        XCTAssertNil(state.ingest(count: 2, at: 1.02))
        XCTAssertNil(state.ingest(count: 3, at: 1.03))
        XCTAssertNil(state.ingest(count: 3, at: 1.06))
        XCTAssertEqual(state.ingest(count: 3, at: 1.08), .press)
        XCTAssertEqual(state.ingest(count: 2, at: 1.081), .release)
    }

    func testEmergencyRequiresReleaseBeforeRearming() {
        var state = ready()
        _ = state.ingest(count: 3, at: 1)
        _ = state.ingest(count: 3, at: 1.1)
        XCTAssertEqual(state.emergencyRelease(), .release)
        XCTAssertNil(state.emergencyRelease())
        XCTAssertNil(state.ingest(count: 3, at: 2))
        _ = state.ingest(count: 0, at: 3)
        _ = state.ingest(count: 3, at: 4)
        XCTAssertEqual(state.ingest(count: 3, at: 4.1), .press)
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
}
