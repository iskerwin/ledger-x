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

    func testOnlyADeletedFileExpiresAfterThirtyDays() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var item = DeletedAttachment(path: "documents/receipts/a.jpg", version: "v1", record: UUID(), time: start)
        XCTAssertFalse(item.expired(now: start.addingTimeInterval(DeletedAttachment.keep + 1)), "the file is still in storage")
        item.state = .deleted
        XCTAssertFalse(item.expired(now: start.addingTimeInterval(DeletedAttachment.keep)))
        XCTAssertTrue(item.expired(now: start.addingTimeInterval(DeletedAttachment.keep + 1)))
    }
}
