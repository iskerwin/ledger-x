import XCTest
import SwiftUI
@testable import Ledger

@MainActor
final class SyncAppearanceTests: XCTestCase {
    func testNormalWaitingAndOfflineAreDifferentFromErrorsAndHeldChanges() {
        let waiting = SyncAppearance(state: .idle, waiting: true, held: false, failed: false)
        let offline = SyncAppearance(state: .offline, waiting: true, held: false, failed: false)
        let held = SyncAppearance(state: .idle, waiting: true, held: true, failed: false)
        let failed = SyncAppearance(state: .idle, waiting: true, held: false, failed: true)
        XCTAssertEqual(waiting, .waiting)
        XCTAssertEqual(offline, .offline)
        XCTAssertEqual(held, .held)
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(waiting.color, .secondary)
        XCTAssertEqual(offline.color, .secondary)
        XCTAssertEqual(held.color, .warn)
        XCTAssertEqual(failed.color, .loss)
        XCTAssertEqual(Set([waiting.symbol, offline.symbol, held.symbol, failed.symbol]).count, 4)
        XCTAssertEqual(Set([waiting.title, offline.title, held.title, failed.title]).count, 4)
    }

    func testActiveRetryShowsProgressAndAnUnresolvedFailureStillWinsAfterwards() {
        XCTAssertEqual(SyncAppearance(state: .syncing, waiting: true, held: true, failed: true), .syncing)
        XCTAssertEqual(SyncAppearance(state: .idle, waiting: true, held: true, failed: true), .failed)
        XCTAssertEqual(SyncAppearance(state: .error, waiting: false, held: false, failed: false), .failed)
        XCTAssertEqual(SyncAppearance(state: .idle, waiting: false, held: false, failed: false), .synced)
    }
}
