import XCTest
@testable import LedgerKit

final class DeletedAttachmentTests: XCTestCase {
    func testReferencesResolveEachDirectiveFromItsOwnFile() {
        let files = [
            "main.bean": """
            include "accounts/documents.bean"
            2026-01-01 open Assets:Bank:DemoBank CNY
            2026-10-01 document Assets:Bank:DemoBank "documents/receipts/receipts_20261001.jpg"
            2026-10-02 document Assets:Bank:DemoBank "documents/receipts/receipts_20261002.jpg"
            """,
            "accounts/documents.bean": """
            2026-10-03 document Assets:Bank:DemoBank "../documents/receipts/receipts_20261001.jpg"
            """,
        ]
        let L = loadLedger(root: "main.bean") { files[$0] ?? "" }
        XCTAssertTrue(L.errors.isEmpty, L.errors.map(\.msg).joined())
        XCTAssertEqual(documentReferences(L, path: "documents/receipts/receipts_20261001.jpg").map(\.date), ["2026-10-01", "2026-10-03"])
        XCTAssertEqual(documentReferences(L, path: "documents/receipts/receipts_20261002.jpg").count, 1)
        XCTAssertTrue(documentReferences(L, path: "documents/receipts/other.jpg").isEmpty)
    }

    func testDaysLeftCountDownFromTheFilesDeletion() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var item = DeletedAttachment(path: "documents/receipts/a.jpg", version: "v1", record: nil, time: start)
        XCTAssertEqual(item.daysLeft(now: start.addingTimeInterval(40 * 86_400)), 30, "still in storage")
        item.state = .deleted
        XCTAssertEqual(item.daysLeft(now: start), 30)
        XCTAssertEqual(item.daysLeft(now: start.addingTimeInterval(1)), 30)
        XCTAssertEqual(item.daysLeft(now: start.addingTimeInterval(29.5 * 86_400)), 1)
        XCTAssertEqual(item.daysLeft(now: start.addingTimeInterval(31 * 86_400)), 0)
    }

    func testAnEarlierSavedCopyStillReads() throws {
        let old = #"[{"id":"9E0B4F7A-0D35-4B8C-9E57-1C4E9E8C0F11","path":"documents/receipts/a.jpg","version":"v1","time":800000000,"state":"deleted"}]"#
        let items = try JSONDecoder().decode([DeletedAttachment].self, from: Data(old.utf8))
        XCTAssertEqual(items.first?.path, "documents/receipts/a.jpg")
        XCTAssertNil(items.first?.text)
    }

    func testOnlyADeletedFileExpiresAfterThirtyDays() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var item = DeletedAttachment(path: "documents/receipts/a.jpg", version: "v1", record: UUID(), time: start)
        XCTAssertFalse(item.expired(now: start.addingTimeInterval(DeletedAttachment.keep + 1)), "the file is still in storage")
        item.state = .deleted
        XCTAssertFalse(item.expired(now: start.addingTimeInterval(DeletedAttachment.keep)))
        XCTAssertTrue(item.expired(now: start.addingTimeInterval(DeletedAttachment.keep + 1)))
    }
}
