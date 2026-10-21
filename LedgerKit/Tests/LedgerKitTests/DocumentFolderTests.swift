import XCTest
@testable import LedgerKit

/// option "documents": the documents Beancount makes from the folders for Fixtures/docs (worked out with
/// Beancount 2.3.6: the explicit document stays, and the same file found in the folder is a second one)
final class DocumentFolderTests: XCTestCase {
    func load(list: Bool = true) -> Ledger {
        let dir = fixtureURL("docs")
        let files: [String] = {
            let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])!
            return en.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .map { String($0.standardizedFileURL.path.dropFirst(dir.standardizedFileURL.path.count + 1)) }
        }()
        return loadLedger(root: "main.bean", listFiles: list ? { files } : nil) { path in
            try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
        }
    }

    func testAsBeancount() {
        let L = load()
        let docs = L.documents.map { "\($0.date) \($0.account ?? "") \($0.path ?? "") \($0.synthetic)" }
        XCTAssertEqual(docs.sorted(), [
            "2024-01-15 Expenses:Travel statements/Expenses/Travel/2024-01-15-hotel.jpg true",
            "2024-01-31 Assets:Bank:Main statements/Assets/Bank/Main/2024-01-31.statement.pdf false",
            "2024-01-31 Assets:Bank:Main statements/Assets/Bank/Main/2024-01-31.statement.pdf true",
            "2024-02-29 Assets:Bank:Main statements/Assets/Bank/Main/2024-02-29.statement.pdf true",
        ])
        // the one Beancount reports: a date that isn't one
        XCTAssertEqual(L.errors.filter { !$0.soft }.map { $0.msg }, [tr("票据文件名的日期不对：2024-02-30.statement.pdf", "Invalid date in a document's file name: 2024-02-30.statement.pdf")])
    }

    func testWithoutAFileList() {
        let L = load(list: false)
        XCTAssertEqual(L.documents.count, 1, "only the one written down")
        XCTAssertTrue(L.errors.contains { $0.soft && $0.msg.contains("documents") })
    }
}
