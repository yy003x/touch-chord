import XCTest
import CoreGraphics
@testable import TriKey

final class ModifierKeyControllerTests: XCTestCase {
    func testSingleKeysAreNeverHeldModifiers() {
        var state = ModifierOwnership()
        XCTAssertFalse(state.press(.returnKey))
        XCTAssertFalse(state.press(.escape))
        XCTAssertNil(state.heldKey)
    }
    func testQueuedSingleKeyKeepsPostedFlagsAfterModifierSwitch() {
        var state = ModifierOwnership()
        let snapshots: [CGEventFlags] = [[], [.maskShift, .maskAlphaShift]]
        _ = state.press(.command)
        for key in [TouchKey.returnKey, .escape] {
            for postedFlags in snapshots {
                XCTAssertEqual(state.postedEventFlags(for: key, base: postedFlags,
                                                     physical: [.option], pending: [.command, .shift, key]),
                               postedFlags)
            }
        }
    }

    func testQueuedModifierReleaseStillReflectsCurrentSources() {
        var state = ModifierOwnership()
        _ = state.press(.option)
        XCTAssertEqual(state.postedEventFlags(for: .command, base: [.maskCommand, .maskAlphaShift],
                                             physical: [.shift], pending: [.command, .option]),
                       [.maskAlternate, .maskShift, .maskAlphaShift])
    }
    func testRecoveryAndQueuedReleaseDoNotReintroduceOldModifiers() {
        var state = ModifierOwnership()
        let base: CGEventFlags = [.maskCommand, .maskShift, .maskAlphaShift]
        XCTAssertEqual(state.eventFlags(base: base, physical: [], pending: [.command, .shift]), .maskAlphaShift)
        _ = state.press(.option)
        XCTAssertEqual(state.eventFlags(base: base, physical: [.control], pending: [.command, .shift, .option]),
                       [.maskAlphaShift, .maskAlternate, .maskControl])
        XCTAssertEqual(state.eventFlags(base: base, physical: [.command], pending: [.command, .shift, .option]),
                       [.maskAlphaShift, .maskAlternate, .maskCommand])
    }
    func testPressAndReleaseAreIdempotentForEveryModifier() {
        for key in TouchKey.modifiers {
            var state = ModifierOwnership()
            XCTAssertTrue(state.press(key))
            for other in TouchKey.modifiers { XCTAssertFalse(state.press(other)) }
            XCTAssertEqual(state.release(physical: []), key)
            XCTAssertNil(state.release(physical: []))
            XCTAssertNil(state.heldKey)
        }
    }

    func testReleasingVirtualDoesNotReleasePhysical() {
        for key in TouchKey.modifiers {
            for physicalFirst in [false, true] {
                var state = ModifierOwnership()
                var physical: Set<TouchKey> = physicalFirst ? [key] : []
                _ = state.press(key)
                physical.insert(key)
                XCTAssertEqual(state.effective(physical: physical), [key])
                XCTAssertNil(state.release(physical: physical))
                XCTAssertEqual(state.effective(physical: physical), [key])
                XCTAssertNil(state.heldKey)
                physical.remove(key)
                XCTAssertTrue(state.effective(physical: physical).isEmpty)
            }
        }
    }

    func testPhysicalReleaseWhileVirtualHeldKeepsEveryModifier() {
        for key in TouchKey.modifiers {
            var state = ModifierOwnership()
            _ = state.press(key)
            XCTAssertEqual(state.effective(physical: [key]), [key])
            XCTAssertEqual(state.effective(physical: []), [key])
            XCTAssertEqual(state.release(physical: []), key)
        }
    }

    func testUnrelatedPhysicalKeysSurviveVirtualSwitch() {
        for key in TouchKey.modifiers {
            let physical = Set(TouchKey.modifiers.filter { $0 != key })
            var state = ModifierOwnership()
            _ = state.press(key)
            XCTAssertEqual(state.effective(physical: physical), Set(TouchKey.modifiers))
            XCTAssertEqual(state.release(physical: physical), key)
            XCTAssertEqual(state.effective(physical: physical), physical)
            _ = state.press(physical.first!)
            XCTAssertNil(state.release(physical: physical))
            XCTAssertEqual(state.effective(physical: physical), physical)
        }
    }
}
