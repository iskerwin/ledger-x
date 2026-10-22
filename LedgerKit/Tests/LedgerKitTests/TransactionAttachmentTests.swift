import XCTest
@testable import LedgerKit

final class TransactionAttachmentTests: XCTestCase {
    func testLinkedDocumentsAreAttachmentsWhateverTheirFolder() {
        let text = """
        2026-01-01 open Assets:Bank:DemoBank:Cash CNY
        2026-01-01 open Expenses:Food CNY
        2026-10-01 * "示例咖啡" "拿铁" ^doc-20261001-a1b2
          Expenses:Food              32.00 CNY
          Assets:Bank:DemoBank:Cash
        2026-10-01 document Assets:Bank:DemoBank:Cash "documents/demobank/demobank_20261001.jpg" ^doc-20261001-a1b2
        2026-10-03 document Assets:Bank:DemoBank:Cash "documents/receipts/receipts_20261003.jpg" ^doc-20261003-c3d4
        2026-10-03 * "示例书店" "书" ^doc-20261003-c3d4
          Expenses:Food              58.00 CNY
          Assets:Bank:DemoBank:Cash
        2026-10-31 document Assets:Bank:DemoBank:Cash "documents/demobank/demobank_20261031.pdf"
        2026-10-31 document Assets:Bank:DemoBank:Cash "documents/demobank/demobank_20261031_1.pdf" ^doc-20261031-e5f6
        """
        let L = loadLedger(root: "main.bean") { _ in text }
        XCTAssertTrue(L.errors.isEmpty, L.errors.map(\.msg).joined())
        // a link no transaction carries leaves the document a statement
        XCTAssertEqual(transactionAttachments(L).map { $0.path }, [
            "documents/receipts/receipts_20261003.jpg",
            "documents/demobank/demobank_20261001.jpg",
        ])
    }

    func testAttachmentsDefaultToTheirOwnFolder() {
        XCTAssertEqual(transactionAttachmentFolder, "receipts")
        XCTAssertNotEqual(transactionAttachmentFolder, documentFolder(for: "Assets:Bank:DemoBank:Cash"))
        XCTAssertEqual(preferredDocumentFileName(folder: transactionAttachmentFolder, date: "2026-10-03", ext: "JPG",
                                                 existingPaths: ["documents/receipts/receipts_20261003.jpg"]),
                       "receipts_20261003_1.jpg")
    }
}
