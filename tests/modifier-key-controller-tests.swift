import XCTest
@testable import TriKey

final class ModifierKeyControllerTests: XCTestCase {
    func testPressAndReleaseAreIdempotent() {
        var state = CommandOwnership()
        XCTAssertTrue(state.press())
        XCTAssertFalse(state.press())
        XCTAssertTrue(state.release(physicalPressed: false))
        XCTAssertFalse(state.release(physicalPressed: false))
        XCTAssertFalse(state.virtualPressed)
    }

    func testReleasingVirtualDoesNotReleasePhysical() {
        var state = CommandOwnership()
        _ = state.press()
        XCTAssertFalse(state.release(physicalPressed: true))
        XCTAssertTrue(state.effective(physicalPressed: true))
        XCTAssertFalse(state.virtualPressed)
        XCTAssertFalse(state.effective(physicalPressed: false))
    }

    func testPhysicalReleaseWhileVirtualHeldKeepsCommand() {
        var state = CommandOwnership()
        _ = state.press()
        XCTAssertTrue(state.effective(physicalPressed: true))
        XCTAssertTrue(state.effective(physicalPressed: false))
        XCTAssertTrue(state.release(physicalPressed: false))
    }
}
