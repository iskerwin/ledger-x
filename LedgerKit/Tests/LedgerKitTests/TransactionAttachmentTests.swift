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

    /// 附件与对账单: every document under its account, attachments with their transaction, statements without one
    func testEveryDocumentIsListedUnderItsAccountWithItsTransaction() {
        let text = """
        2026-01-01 open Assets:Bank:DemoBank:Cash CNY
        2026-01-01 open Liabilities:CreditCard:DemoBank CNY
        2026-01-01 open Expenses:Food CNY
        2026-10-01 * "示例咖啡" "拿铁" ^doc-20261001-a1b2
          Expenses:Food              32.00 CNY
          Liabilities:CreditCard:DemoBank
        2026-10-01 document Liabilities:CreditCard:DemoBank "documents/receipts/receipts_20261001.jpg" ^doc-20261001-a1b2
        2026-10-31 document Assets:Bank:DemoBank:Cash "documents/demobank/demobank_20261031.pdf"
        2026-11-01 document Liabilities:CreditCard:DemoBank "documents/demobank/demobank_20261101.pdf"
        """
        let L = loadLedger(root: "main.bean") { _ in text }
        let items = documentItems(L)
        XCTAssertEqual(items.map(\.name), ["demobank_20261101.pdf", "demobank_20261031.pdf", "receipts_20261001.jpg"])
        XCTAssertEqual(items.map(\.isAttachment), [false, false, true])
        XCTAssertEqual(items.last?.transaction?.payee, "示例咖啡")
        XCTAssertEqual(items.first?.path, "documents/demobank/demobank_20261101.pdf")
        let groups = documentGroups(items)
        XCTAssertEqual(groups.map(\.account), ["Assets:Bank:DemoBank:Cash", "Liabilities:CreditCard:DemoBank"])
        XCTAssertEqual(groups[1].items.map(\.name), ["demobank_20261101.pdf", "receipts_20261001.jpg"])
        XCTAssertEqual(items.filter { documentMatches($0, "咖啡", L) }.map(\.name), ["receipts_20261001.jpg"])
        XCTAssertEqual(items.filter { documentMatches($0, "1031", L) }.count, 1)
        XCTAssertEqual(items.filter { documentMatches($0, "creditcard", L) }.count, 2)
        XCTAssertEqual(items.filter { documentMatches($0, " ", L) }.count, 3)
    }
}
