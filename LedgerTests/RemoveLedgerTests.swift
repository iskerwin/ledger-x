import XCTest
@testable import Ledger
import LedgerKit

/// Deleting a ledger from the phone also deletes its unsent attachments (photos included) and an unfinished
/// import with its statement; they used to stay behind.
@MainActor
final class RemoveLedgerTests: XCTestCase {
    func testRemovingALedgerRemovesItsRecoveryFiles() throws {
        let store = Store()
        var current = RepoConfig(); current.id = "remove-current-" + UUID().uuidString; current.kind = .local
        var other = RepoConfig(); other.id = "remove-other-" + UUID().uuidString; other.kind = .local
        store.sources += [current, other]
        store.cfg = current
        // the list of ledgers is saved by removeLedger: take the test's own one off again afterwards
        defer { store.cfg = RepoConfig(); store.removeLedger(current.id) }
        try RecoveryFiles.save(["fictional"], kind: "attachments", ledger: other.id)
        try RecoveryFiles.save(["fictional"], kind: "import", ledger: other.id)
        try RecoveryFiles.saveData(Data("; fictional statement".utf8), kind: "import-source", ledger: other.id)
        store.removeLedger(other.id)
        XCTAssertNil(RecoveryFiles.load([String].self, kind: "attachments", ledger: other.id))
        XCTAssertNil(RecoveryFiles.load([String].self, kind: "import", ledger: other.id))
        XCTAssertNil(RecoveryFiles.loadData(kind: "import-source", ledger: other.id))
        XCTAssertFalse(store.sources.contains { $0.id == other.id })
    }
}
