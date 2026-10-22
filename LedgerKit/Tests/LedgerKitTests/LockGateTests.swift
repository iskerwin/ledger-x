import XCTest
@testable import LedgerKit

final class LockGateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testCancellingFaceIDDoesNotAskAgainByItself() {
        var gate = LockGate(enabled: true, grace: 0, locked: true)
        // the Face ID panel: inactive while it is up, active again once it is cancelled
        XCTAssertFalse(gate.phase(.inactive, now: start))
        XCTAssertFalse(gate.phase(.active, now: start.addingTimeInterval(2)))
        XCTAssertTrue(gate.locked)
        // the passcode panel the user chose does the same
        XCTAssertFalse(gate.phase(.inactive, now: start.addingTimeInterval(3)))
        XCTAssertFalse(gate.phase(.active, now: start.addingTimeInterval(9)))
        XCTAssertTrue(gate.locked)
    }

    func testReturningFromTheBackgroundAsksOnce() {
        var gate = LockGate(enabled: true, grace: 0, locked: false)
        XCTAssertFalse(gate.phase(.inactive, now: start))
        XCTAssertFalse(gate.phase(.background, now: start))
        XCTAssertTrue(gate.locked)
        XCTAssertFalse(gate.phase(.inactive, now: start.addingTimeInterval(5)))
        XCTAssertTrue(gate.phase(.active, now: start.addingTimeInterval(5)))
        // cancelled: the panel's own round trip does not ask again
        XCTAssertFalse(gate.phase(.inactive, now: start.addingTimeInterval(6)))
        XCTAssertFalse(gate.phase(.active, now: start.addingTimeInterval(7)))
        XCTAssertTrue(gate.locked)
    }

    func testGraceKeepsAShortTripUnlocked() {
        var gate = LockGate(enabled: true, grace: 60, locked: false)
        XCTAssertFalse(gate.phase(.background, now: start))
        XCTAssertFalse(gate.locked)
        XCTAssertFalse(gate.phase(.active, now: start.addingTimeInterval(59)))
        XCTAssertFalse(gate.locked)
        XCTAssertFalse(gate.phase(.background, now: start.addingTimeInterval(100)))
        XCTAssertTrue(gate.phase(.active, now: start.addingTimeInterval(160)))
        XCTAssertTrue(gate.locked)
    }

    func testTurnedOffUnlocks() {
        var gate = LockGate(enabled: false, grace: 0, locked: true)
        XCTAssertFalse(gate.phase(.background, now: start))
        XCTAssertFalse(gate.phase(.active, now: start.addingTimeInterval(1)))
        XCTAssertFalse(gate.locked)
    }
}
