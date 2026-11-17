import XCTest
@testable import LedgerKit

/// The Mac's 个人往来 saves (lend, collect, borrow, repay), written straight into a folder
final class FolderLoanTests: XCTestCase {
    private var folder: URL!
    private let day = Day.shift(Day.today(), -5)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = """
        option "operating_currency" "CNY"
        2023-01-01 open Assets:Bank
        2023-01-01 open Assets:Receivable:Personal
        2023-01-01 open Expenses:Food
        2023-01-01 open Equity:Opening

        2023-01-02 * "Opening"
          Assets:Bank                 1000.00 CNY
          Equity:Opening

        \(Day.shift(Day.today(), -20)) * "Sample Diner" "Dinner"
          Expenses:Food                 60.00 CNY
          Assets:Receivable:Personal    40.00 CNY
            person: "Alex"
          Assets:Bank                 -100.00 CNY

        """
        try text.write(to: folder.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func draft(_ kind: LoanKind, name: String = "Alex", amount: String = "") -> LoanDraft {
        var d = LoanDraft()
        d.kind = kind
        d.date = day
        d.name = name
        d.amount = amount
        d.account = "Assets:Bank"
        return d
    }

    private func saved(_ d: LoanDraft) throws -> Ledger {
        let save = try prepareFolderLoan(d, folder: folder).get()
        XCTAssertTrue(save.issues.isEmpty, "\(save.issues)")
        try commitFolderSave(save, folder: folder)
        return try XCTUnwrap(loadLedger(folder: folder))
    }

    func testCollectingWithNoAmountTakesWhatIsOwed() throws {
        let ledger = try saved(draft(.collect))
        XCTAssertEqual(people(ledger).first { $0.name == "Alex" }?.settled, true)
    }

    func testLendingIsWrittenOnThePersonalReceivableWithTheirName() throws {
        let ledger = try saved(draft(.lend, amount: "25"))
        XCTAssertEqual(people(ledger).first { $0.name == "Alex" }?.net["CNY"] ?? 0, 65, accuracy: 0.001)
    }

    func testBorrowingFromSomeoneNewOpensTheirLoanAccount() throws {
        var d = draft(.borrow, name: "Sam", amount: "300")
        d.key = "Sam"
        let ledger = try saved(d)
        XCTAssertNotNil(ledger.accounts["Liabilities:Loan:Sam"])
        XCTAssertEqual(people(ledger).first { $0.name == "Sam" }?.net["CNY"] ?? 0, -300, accuracy: 0.001)
    }

    func testNothingToCollectWritesNothing() {
        XCTAssertThrowsError(try prepareFolderLoan(draft(.collect, name: "Nobody"), folder: folder).get())
    }
}
