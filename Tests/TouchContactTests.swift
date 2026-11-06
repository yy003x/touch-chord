import XCTest
@testable import TriKeyHardware

final class TouchContactTests: XCTestCase {
    func testPrivateLayoutAssumption() {
        // 只能检查本地内存布局；不代表系统提供的私有 ABI 已获验证。
        XCTAssertTrue(MTContact.layoutMatches)
    }

    func testOnlyContactPhasesCount() {
        XCTAssertEqual((Int32(0)...7).filter(MTContact.isTouching), [3, 4])
        XCTAssertFalse(MTContact.isTouching(-1))
        XCTAssertFalse(MTContact.isTouching(8))
    }
}
