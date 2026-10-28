import XCTest
@testable import Ledger
import LedgerKit

/// The sync queue lives in a file of its own per ledger; a queue left in UserDefaults by an earlier version is
/// moved over once, and forgetting a ledger removes both.
@MainActor
final class PendingQueueTests: XCTestCase {
    private func op(_ text: String) -> Op {
        var op = Op(kind: .write, path: "main.bean")
        op.text = text
        return op
    }

    func testAQueueLeftInUserDefaultsMovesToItsFile() throws {
        let ledger = "queue-test-" + UUID().uuidString
        defer { PendingQueue.remove(ledger: ledger) }
        Prefs.set(Store.key("pending", ledger), [op("; fictional")])
        XCTAssertEqual(PendingQueue.load(ledger: ledger).map(\.text), ["; fictional"])
        XCTAssertNil(UserDefaults.standard.data(forKey: "ledger." + Store.key("pending", ledger)), "moved, not copied")
        XCTAssertEqual(PendingQueue.load(ledger: ledger).map(\.text), ["; fictional"], "read back from the file")

        try PendingQueue.save([op("; one"), op("; two")], ledger: ledger)
        XCTAssertEqual(PendingQueue.load(ledger: ledger).map(\.text), ["; one", "; two"])
        PendingQueue.remove(ledger: ledger)
        XCTAssertTrue(PendingQueue.load(ledger: ledger).isEmpty)
    }
}
