import XCTest
@testable import LedgerKit

final class FolderLedgerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func txn(_ narration: String) -> String {
        """
        2026-10-16 * "\(narration)"
          Assets:Bank  -10.00 CNY
          Expenses:Food  10.00 CNY

        """
    }

    func testReadsMainBeanAndItsWildcardIncludes() throws {
        try write("main.bean", "include \"journals/*.bean\"\n" + txn("Main"))
        try write("journals/2026.bean", txn("Included"))
        let ledger = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertEqual(Set(ledger.txns.map(\.narration)), ["Main", "Included"])
    }

    func testStartsFromTheMainFileInLedgerXConfig() throws {
        try write("main.bean", txn("Ignored"))
        try write("books/root.bean", txn("Root"))
        try write(LedgerXConfig.path, "{\"main\": \"books/root.bean\"}")
        let ledger = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertEqual(ledger.txns.map(\.narration), ["Root"])
    }

    func testReadsTheAccountsLeftOutFromLedgerXConfig() throws {
        XCTAssertNil(ledgerConfig(folder: folder))
        try write(LedgerXConfig.path, "{\"networth_exclude\": [\"Assets:House\"], \"balance_exclude\": [\"Assets:Car\"]}")
        let config = try XCTUnwrap(ledgerConfig(folder: folder))
        XCTAssertEqual(config.netWorthExclude, ["Assets:House"])
        XCTAssertEqual(config.balanceExclude, ["Assets:Car"])
    }

    func testFolderWithoutTheMainFileHasNoLedger() throws {
        try write("notes.txt", "not a ledger")
        XCTAssertNil(loadLedger(folder: folder))
    }
}
