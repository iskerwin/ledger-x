import XCTest
import Observation
@testable import Ledger

/// A page is redrawn only for what it reads. Every change to the store used to redraw every page, the hidden tabs
/// too, several times for one save: 保存再记 and the detail page after a refund stalled for seconds.
@MainActor
final class StoreObservationTests: XCTestCase {
    func testWhatASaveChangesBesidesTheLedgerLeavesLedgerPagesAlone() {
        let store = Store()
        var redrawn = false
        withObservationTracking {
            _ = store.L; _ = store.D; _ = store.version
        } onChange: { redrawn = true }
        // what a save and its sync change on the way, without a new ledger
        store.justSaved = "2026-10-25 * \"Example\""
        store.syncError = "offline"
        store.attachmentRevision += 1
        store.closeAddRequested = true
        store.popToken += 1
        store.scanInfo = nil
        XCTAssertFalse(redrawn)
    }

    func testAPageIsRedrawnForWhatItReads() {
        let store = Store()
        var redrawn = false
        withObservationTracking { _ = store.justSaved } onChange: { redrawn = true }
        store.justSaved = "2026-10-25 * \"Example\""
        XCTAssertTrue(redrawn)
    }
}
