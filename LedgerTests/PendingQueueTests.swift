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

    private func queue(_ ledger: String) -> [String?] {
        if case .value(let ops) = PendingQueue.read(ledger: ledger) { return ops.map(\.text) }
        return ["(not read)"]
    }

    func testAQueueLeftInUserDefaultsMovesToItsFile() throws {
        let ledger = "queue-test-" + UUID().uuidString
        defer { PendingQueue.remove(ledger: ledger) }
        Prefs.set(Store.key("pending", ledger), [op("; fictional")])
        XCTAssertEqual(queue(ledger), ["; fictional"])
        XCTAssertNil(UserDefaults.standard.data(forKey: "ledger." + Store.key("pending", ledger)), "moved, not copied")
        XCTAssertEqual(queue(ledger), ["; fictional"], "read back from the file")

        try PendingQueue.save([op("; one"), op("; two")], ledger: ledger)
        XCTAssertEqual(queue(ledger), ["; one", "; two"])
        PendingQueue.remove(ledger: ledger)
        XCTAssertTrue(queue(ledger).isEmpty)
    }
}
