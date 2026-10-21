import XCTest
@testable import LedgerKit

/// Kerwin's document layout: documents/<folder>/<folder>_YYYYMMDD[_n].<ext>
/// Examples use fictional institutions only.
final class DocumentPathTests: XCTestCase {
    func testFolderUsesTheInstitutionAndSharesABankWithItsCard() {
        XCTAssertEqual(documentFolder(for: "Assets:Bank:DemoBank:Cash"), "demobank")
        XCTAssertEqual(documentFolder(for: "Assets:Bank:DemoBank"), "demobank")
        XCTAssertEqual(documentFolder(for: "Liabilities:CreditCard:DemoBank"), "demobank")
        XCTAssertEqual(documentFolder(for: "Liabilities:CreditCard:DemoBank:CNY"), "demobank")
        XCTAssertEqual(documentFolder(for: "Assets:EWallet:DemoPay"), "demopay")
        XCTAssertEqual(documentFolder(for: "Assets:Cash"), "cash")
        XCTAssertEqual(documentFolder(for: "Liabilities:Loan"), "loan")
        XCTAssertEqual(documentFolder(for: "assets:cash"), "cash")
    }

    func testOtherAccountsUseTheLastPart() {
        XCTAssertEqual(documentFolder(for: "Expenses:Food:Demo"), "demo")
        XCTAssertEqual(documentFolder(for: "Income:Salary"), "salary")
        XCTAssertEqual(documentFolder(for: "Equity:Opening-Balances"), "opening-balances")
        XCTAssertEqual(documentFolder(for: "Assets:Bank:示例银行:活期"), "示例银行")
    }

    func testUnusableFolderPartsAreRejected() {
        XCTAssertEqual(documentFolder(for: ""), "")
        XCTAssertEqual(documentFolder(for: ":"), "")
        XCTAssertEqual(documentFolder(for: "Assets:Bank:..:Cash"), "")
        XCTAssertEqual(documentFolder(for: "Assets:Bank:A/B:Cash"), "")
    }

    func testDateStampAndExtension() {
        XCTAssertEqual(documentDateStamp("2026-10-19"), "20261019")
        XCTAssertEqual(documentDateStamp("20261019"), "20261019")
        XCTAssertEqual(documentDateStamp("2026-1-19"), "")
        XCTAssertEqual(documentDateStamp("2026/10/19"), "")
        XCTAssertEqual(normalizedDocumentExtension("PDF"), "pdf")
        XCTAssertEqual(normalizedDocumentExtension("jp g"), "jpg")
        XCTAssertEqual(normalizedDocumentExtension(""), "")
    }

    func testDefaultNameSkipsFilesAlreadyInTheTree() {
        let folder = "demobank"
        let date = "2026-10-19"
        XCTAssertEqual(preferredDocumentFileName(folder: folder, date: date, ext: "pdf", existingPaths: []), "demobank_20261019.pdf")
        let first = "documents/demobank/demobank_20261019.pdf"
        let second = "documents/demobank/demobank_20261019_1.pdf"
        XCTAssertEqual(preferredDocumentFileName(folder: folder, date: date, ext: "PDF", existingPaths: [first]), "demobank_20261019_1.pdf")
        XCTAssertEqual(preferredDocumentFileName(folder: folder, date: date, ext: "pdf", existingPaths: [first, second]), "demobank_20261019_2.pdf")
        // a missing _1 is used before a higher suffix; another folder or extension does not collide
        XCTAssertEqual(preferredDocumentFileName(folder: folder, date: date, ext: "pdf", existingPaths: [first, "documents/demobank/demobank_20261019_3.pdf"]), "demobank_20261019_1.pdf")
        XCTAssertEqual(preferredDocumentFileName(folder: folder, date: date, ext: "jpg", existingPaths: [first]), "demobank_20261019.jpg")
        XCTAssertEqual(preferredDocumentFileName(folder: "cash", date: date, ext: "pdf", existingPaths: [first]), "cash_20261019.pdf")
        XCTAssertEqual(preferredDocumentFileName(folder: "demobank", date: date, ext: "", existingPaths: []), "demobank_20261019")
        XCTAssertEqual(preferredDocumentFileName(folder: "", date: date, ext: "pdf", existingPaths: []), "")
        XCTAssertEqual(preferredDocumentFileName(folder: folder, date: "bad", ext: "pdf", existingPaths: []), "")
    }

    func testDenseNamesContinuePastTenThousandWithoutReturningACollision() {
        let paths = Set((0...10000).map { n in
            "documents/demobank/demobank_20261019" + (n == 0 ? "" : "_\(n)") + ".jpg"
        })
        XCTAssertEqual(preferredDocumentFileName(folder: "demobank", date: "2026-10-19", ext: "jpg", existingPaths: paths), "demobank_20261019_10001.jpg")
    }

    func testStoredPathAndNameChecks() {
        XCTAssertEqual(documentFileStem("demobank_20261019.pdf", ext: "PDF"), "demobank_20261019")
        XCTAssertEqual(documentFileName(stem: "  monthly  ", ext: "pdf"), "monthly.pdf")
        XCTAssertEqual(documentStoragePath(folder: "demobank", fileName: "demobank_20261019.pdf"), "documents/demobank/demobank_20261019.pdf")
        XCTAssertNil(documentStoragePath(folder: "demo/bank", fileName: "a.pdf"))
        XCTAssertNil(documentStoragePath(folder: "demobank", fileName: ""))
        XCTAssertNil(documentStoragePath(folder: "..", fileName: "a.pdf"))
        XCTAssertEqual(documentNameIssue("  "), .empty)
        XCTAssertEqual(documentNameIssue("a/b"), .separator)
        XCTAssertEqual(documentNameIssue("a\\b"), .separator)
        XCTAssertEqual(documentNameIssue("a\"b"), .separator)
        XCTAssertEqual(documentNameIssue("a\nb"), .separator)
        XCTAssertEqual(documentNameIssue("."), .reserved)
        XCTAssertEqual(documentNameIssue(".."), .reserved)
        XCTAssertNil(documentNameIssue("demo bank"))
    }

    func testFoldersComeFromTheDocumentsTreeOnly() {
        let paths = [
            "documents/demobank/demobank_20261019.pdf",
            "documents/demobank/nested/older.pdf",
            "documents/cash/cash_20261018.jpg",
            "documents/readme.pdf",
            "documents//skip.pdf",
            "documents/../escape.pdf",
            "journals/2026.bean",
            "statements/Assets/Bank/Main/2024-01-31.statement.pdf",
        ]
        XCTAssertEqual(documentFolders(in: paths), ["cash", "demobank"])
    }

    func testDirectiveLineStaysTheSameShape() {
        let path = "documents/demobank/demobank_20261019.pdf"
        XCTAssertEqual(
            documentText(date: "2026-10-19", account: "Assets:Bank:DemoBank", path: path),
            "2026-10-19 document Assets:Bank:DemoBank \"\(path)\""
        )
        let spaced = "documents/demo bank/demo bank_20261019.pdf"
        XCTAssertEqual(
            documentText(date: "2026-10-19", account: "Assets:Cash", path: spaced),
            "2026-10-19 document Assets:Cash \"\(spaced)\""
        )
        XCTAssertEqual(documentPath(relativeDocumentPath(path, from: "journals/2026.bean"), from: "journals/2026.bean"), path)
    }

    func testPayingAccountIsWhoPaysAndTransfersUseTheFromSide() {
        XCTAssertEqual(documentPayingAccount([
            posting("Expenses:Food:Demo", 20),
            posting("Liabilities:CreditCard:DemoBank", -20),
        ]), "Liabilities:CreditCard:DemoBank")
        XCTAssertEqual(documentPayingAccount([
            posting("Assets:Bank:DemoBank", 100),
            posting("Assets:EWallet:DemoPay", -100),
        ]), "Assets:EWallet:DemoPay")
        XCTAssertEqual(documentPayingAccount([
            posting("Expenses:Fee:Bank", 2),
            posting("Assets:Bank:DemoBank", 100),
            posting("Assets:EWallet:DemoPay", -102),
        ]), "Assets:EWallet:DemoPay")
        XCTAssertEqual(documentPayingAccount([
            posting("Liabilities:CreditCard:OtherCard", 500),
            posting("Assets:Bank:DemoBank", -500),
        ]), "Assets:Bank:DemoBank")
        XCTAssertEqual(documentFolder(for: "Assets:Bank:DemoBank"), documentFolder(for: "Liabilities:CreditCard:DemoBank"))
        XCTAssertEqual(documentPayingAccount([
            posting("Income:Salary", -5000),
            posting("Assets:Bank:DemoBank", 5000),
        ]), "Assets:Bank:DemoBank")
        XCTAssertEqual(documentPayingAccount([
            posting("Expenses:Food:Demo", -10),
            posting("Assets:Bank:DemoBank", 10),
        ]), "Assets:Bank:DemoBank")
        XCTAssertEqual(documentPayingAccount([
            posting("Expenses:Food:Demo", 30),
            posting("Assets:Cash", -10),
            posting("Liabilities:CreditCard:DemoBank", -20),
        ]), "Liabilities:CreditCard:DemoBank")
        XCTAssertEqual(documentPayingAccount([
            posting("Expenses:Food:Demo", 30),
            posting("Assets:Cash", -15),
            posting("Liabilities:CreditCard:DemoBank", -15),
        ]), "Assets:Cash")
        XCTAssertEqual(documentPayingAccount([posting("Expenses:Food:Demo", 10)]), "Expenses:Food:Demo")
        XCTAssertEqual(documentPayingAccount([posting("Assets:Cash", nil)]), "Assets:Cash")
        XCTAssertEqual(documentPayingAccount([]), "")
    }

    private func posting(_ account: String, _ units: Double?) -> Posting {
        let posting = Posting(account: account)
        posting.units = units
        return posting
    }
}
