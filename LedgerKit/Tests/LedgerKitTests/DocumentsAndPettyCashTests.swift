import XCTest
@testable import LedgerKit

final class DocumentsAndPettyCashTests: XCTestCase {
    func testDocumentPathsStayInsideLedger() {
        XCTAssertEqual(documentPath("../documents/statement.pdf", from: "accounts/document.bean"), "documents/statement.pdf")
        XCTAssertEqual(documentPath("./documents/a.pdf", from: "main.bean"), "documents/a.pdf")
        XCTAssertEqual(documentPath("/Users/me/book/documents/a.pdf", from: "accounts/document.bean"), "documents/a.pdf")
        XCTAssertNil(documentPath("../../outside.pdf", from: "accounts/document.bean"))
        XCTAssertNil(documentPath("/Users/me/private/a.pdf", from: "main.bean"))
        XCTAssertNil(documentPath("", from: "main.bean"))
        for file in ["main.bean", "accounts/document.bean", "nested/accounts/docs.bean"] {
            let path = "documents/2026/statement.pdf"
            XCTAssertEqual(documentPath(relativeDocumentPath(path, from: file), from: file), path)
        }
    }

    func testDocumentEscapingAndPlacement() throws {
        let path = "../documents/2026/bank \"A\".pdf"
        let text = "2026-01-01 open Assets:Bank:CNY CNY\n" + documentText(date: "2026-10-17", account: "Assets:Bank:CNY", path: path)
        let L = loadLedger(root: "accounts/documents.bean") { _ in text }
        XCTAssertTrue(L.errors.isEmpty, L.errors.map(\.msg).joined())
        let document = try XCTUnwrap(L.documents.first)
        XCTAssertEqual(document.path, path)
        XCTAssertEqual(documentPath(document.path!, from: document.file), "documents/2026/bank \"A\".pdf")
        XCTAssertTrue(L.txns.isEmpty, "Documents do not create money movements")
    }

    func testPettyCashCanBeSpentAndReturned() throws {
        let receipt = pettyCashText(date: "2026-10-01", company: "示例公司", amount: 1000, currency: "CNY",
                                   account: "Assets:Bank:CNY", receivable: "Assets:Receivable:Reimbursement", link: "float-company-20261001")
        let base = """
        2026-01-01 open Assets:Bank:CNY CNY
        2026-01-01 open Assets:Receivable:Reimbursement CNY
        """
        let received = loadLedger { _ in base + "\n" + receipt }
        XCTAssertTrue(received.errors.isEmpty, received.errors.map(\.msg).joined())
        XCTAssertEqual(received.final["Assets:Bank:CNY"]?["CNY"], 1000)
        XCTAssertEqual(Derived(received).floats.first?.left, 1000)
        let spent = """
        2026-10-02 * "酒店" "垫付" #reimbursed ^float-company-20261001
          Assets:Receivable:Reimbursement 300.00 CNY
          Assets:Bank:CNY -300.00 CNY
        """
        let partiallyUsed = loadLedger { _ in base + "\n" + receipt + "\n" + spent }
        XCTAssertTrue(partiallyUsed.errors.isEmpty)
        XCTAssertEqual(Derived(partiallyUsed).floats.first?.left, 700)
        let returned = """
        2026-10-03 * "示例公司" "退回剩余" ^float-company-20261001
          Assets:Receivable:Reimbursement 700.00 CNY
          Assets:Bank:CNY -700.00 CNY
        """
        let settled = loadLedger { _ in base + "\n" + receipt + "\n" + spent + "\n" + returned }
        XCTAssertTrue(settled.errors.isEmpty)
        XCTAssertEqual(settled.final["Assets:Receivable:Reimbursement"]?["CNY"] ?? 0, 0)
        XCTAssertTrue(Derived(settled).floats.allSatisfy { abs($0.left) < 0.005 })
    }

    func testPettyCashRejectsInvalidInputAndKeepsCurrency() {
        func text(_ amount: Double, _ account: String = "Assets:Bank:USD", _ link: String = "float-company-20261001") -> String {
            pettyCashText(date: "2026-10-01", company: "Company", amount: amount, currency: "USD", account: account,
                          receivable: "Assets:Receivable:Reimbursement", link: link)
        }
        XCTAssertEqual(text(0), "")
        XCTAssertEqual(text(-1), "")
        XCTAssertEqual(text(.nan), "")
        XCTAssertEqual(text(100, "Assets:Receivable:Reimbursement"), "")
        XCTAssertEqual(text(100, "Assets:Bank:USD", "refund-wrong"), "")
        let L = loadLedger { _ in "2026-01-01 open Assets:Bank:USD USD\n2026-01-01 open Assets:Receivable:Reimbursement\n" + text(12.345) }
        XCTAssertTrue(L.errors.isEmpty)
        XCTAssertEqual(L.final["Assets:Bank:USD"]?["USD"], 12.35)
    }
}
