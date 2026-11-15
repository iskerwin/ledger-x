import XCTest
import Observation
@testable import Ledger

/// A page is redrawn only for what it reads. Every change to the store used to redraw every page, the hidden tabs
/// too, several times for one save: 保存再记 and the detail page after a refund stalled for seconds.
@MainActor
final class StoreObservationTests: XCTestCase {
    func testWhatASaveChangesBesidesTheLedgerLeavesLedgerPagesAlone() {
        let store = Store()
        let redrawn = Flag()
        withObservationTracking {
            _ = store.L; _ = store.D; _ = store.version
        } onChange: { redrawn.set() }
        // what a save and its sync change on the way, without a new ledger
        store.justSaved = "2026-10-25 * \"Example\""
        store.syncError = "offline"
        store.attachmentRevision += 1
        store.closeAddRequested = true
        store.popToken += 1
        XCTAssertFalse(redrawn.value)
    }

    func testAPageIsRedrawnForWhatItReads() {
        let store = Store()
        let redrawn = Flag()
        withObservationTracking { _ = store.justSaved } onChange: { redrawn.set() }
        store.justSaved = "2026-10-25 * \"Example\""
        XCTAssertTrue(redrawn.value)
    }
}

/// set from the observation's change handler, which may run on another thread
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    func set() { lock.lock(); raised = true; lock.unlock() }
}
