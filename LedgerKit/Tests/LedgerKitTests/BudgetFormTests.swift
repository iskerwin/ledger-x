import XCTest
@testable import LedgerKit

final class BudgetFormTests: XCTestCase {
    private var folder: URL!
    private let source = """
    2026-01-01 open Assets:Cash CNY
    2026-01-01 open Expenses:Food:Drinks CNY
    2026-01-01 open Equity:Opening CNY
    2026-01-01 * "Sample opening"
      Assets:Cash 1000.00 CNY
      Equity:Opening -1000.00 CNY
    2026-02-10 * "Sample cafe"
      Expenses:Food:Drinks 25.00 CNY
      Assets:Cash -25.00 CNY

    """
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(source)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func write(_ text: String) throws { try text.write(to: folder.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8) }
    private func read() throws -> String { try String(contentsOf: folder.appendingPathComponent("main.bean"), encoding: .utf8) }
    private func ledger() throws -> Ledger { try XCTUnwrap(loadLedger(folder: folder)) }
    private func form(_ amount: String = "100", date: String = "2026-02-01") -> BudgetForm {
        var form = BudgetForm(currency: "CNY", date: date)
        form.account = "Expenses:Food"
        form.amount = amount
        return form
    }
    private func save(_ form: BudgetForm, replacing: Entry? = nil, previous: Entry? = nil) throws {
        let prepared = try prepareFolderBudget(form, replacing: replacing, previous: previous, folder: folder).get()
        XCTAssertEqual(prepared.issues, [])
        try commitFolderSave(prepared, folder: folder)
    }

    func testNewBudgetUsesLayoutAndCountsSubaccounts() throws {
        var config = LedgerXConfig()
        config.files["budget"] = "plans/budget.bean"
        let p = folder.appendingPathComponent(LedgerXConfig.path)
        try config.json().write(to: p, atomically: true, encoding: .utf8)
        try save(form("50+50"))
        XCTAssertTrue(try read().contains("include \"plans/budget.bean\""))
        let progress = budgetProgress(try ledger(), key: "2026-02", today: "2026-02-15")
        XCTAssertEqual(progress.first?.spent, 25)
        XCTAssertEqual(progress.first?.limit, 100)
    }

    func testLaterChangeAndStopPreserveHistory() throws {
        try save(form("100", date: "2026-01-01"))
        let first = try XCTUnwrap(budgets(try ledger()).first?.entry)
        try save(form("200"), previous: first)
        let latest = try XCTUnwrap(budgets(try ledger()).last?.entry)
        try save(form("0", date: "2026-03-01"), previous: latest)
        let after = try ledger()
        XCTAssertEqual(budgets(after).map(\.amount), [100, 200, 0])
        XCTAssertEqual(activeBudgets(after, at: "2026-01-15").first?.amount, 100)
        XCTAssertEqual(activeBudgets(after, at: "2026-02-15").first?.amount, 200)
        XCTAssertTrue(activeBudgets(after, at: "2026-03-15").isEmpty)
    }

    func testSameDayReplacementKeepsMetadataAndOnlyOneRecord() throws {
        try write(source + budgetLine("2026-02-01", "Expenses:Food", .monthly, 100, "CNY") + "\n  owner: \"Example\"\n  ; keep this comment\n")
        let original = try XCTUnwrap(budgets(try ledger()).first?.entry)
        try save(form("200"), replacing: original, previous: original)
        XCTAssertEqual(budgets(try ledger()).map(\.amount), [200])
        XCTAssertTrue(try read().contains("owner: \"Example\""))
        XCTAssertTrue(try read().contains("; keep this comment"))
    }

    func testSameDayRecordRequiresTheExactSnapshot() throws {
        try save(form())
        guard case .failure = prepareFolderBudget(form("200"), folder: folder) else { return XCTFail("must not silently replace") }
        let old = try XCTUnwrap(budgets(try ledger()).first?.entry)
        try write(try read().replacingOccurrences(of: "100.00 CNY", with: "150.00 CNY"))
        guard case .failure = prepareFolderBudget(form("200"), replacing: old, folder: folder) else { return XCTFail("stale record") }
        XCTAssertEqual(budgets(try ledger()).map(\.amount), [150])
    }

    func testNewerBudgetAddedWhileAdjustingIsNotOverridden() throws {
        try save(form("100", date: "2026-01-01"))
        let old = try XCTUnwrap(budgets(try ledger()).first?.entry)
        try save(form("150", date: "2026-02-01"))
        guard case .failure = prepareFolderBudget(form("0", date: "2026-03-01"), previous: old, folder: folder) else { return XCTFail("stale active budget") }
        XCTAssertEqual(budgets(try ledger()).map(\.amount), [100, 150])
    }

    func testDateMoveCannotDisplaceAnotherRecord() throws {
        try save(form("100", date: "2026-01-01"))
        try save(form("200", date: "2026-02-01"))
        let old = try XCTUnwrap(budgets(try ledger()).first?.entry)
        guard case .failure = prepareFolderBudget(form("300"), replacing: old, folder: folder) else { return XCTFail("another dated record") }
        XCTAssertEqual(budgets(try ledger()).map(\.amount), [100, 200])
    }

    func testPreparedBudgetRefusesExternalFileChanges() throws {
        let prepared = try prepareFolderBudget(form(), folder: folder).get()
        try write(source + "; external edit\n")
        XCTAssertThrowsError(try commitFolderSave(prepared, folder: folder))
        XCTAssertTrue(budgets(try ledger()).isEmpty)
    }

    func testMovingTheEffectiveDateKeepsChronologicalOrder() throws {
        try save(form())
        let original = try XCTUnwrap(budgets(try ledger()).first?.entry)
        try save(form("200", date: "2026-03-01"), replacing: original)
        let entries = parseFile(try read(), file: "main.bean").entries
        XCTAssertEqual(entries.map(\.date), entries.map(\.date).sorted())
        XCTAssertTrue(activeBudgets(try ledger(), at: "2026-02-15").isEmpty)
        XCTAssertEqual(activeBudgets(try ledger(), at: "2026-03-15").first?.amount, 200)
    }

    func testDeletingAHistoryRecordRestoresTheEarlierBudget() throws {
        try save(form("100", date: "2026-01-01"))
        try save(form("0", date: "2026-02-01"))
        let stop = try XCTUnwrap(budgets(try ledger()).last?.entry)
        try commitFolderSave(try prepareFolderDelete(stop, folder: folder).get(), folder: folder)
        XCTAssertEqual(activeBudgets(try ledger(), at: "2026-02-15").first?.amount, 100)
        XCTAssertEqual(try ledger().txns.count, 2)
    }

    func testInvalidFieldsCannotWrite() throws {
        var bad = form()
        for amount in ["", "-1", "nan"] {
            bad.amount = amount
            guard case .failure = prepareFolderBudget(bad, folder: folder) else { return XCTFail(amount) }
        }
        bad = form(); bad.date = "2026-02-30"
        guard case .failure = prepareFolderBudget(bad, folder: folder) else { return XCTFail("invalid day") }
        bad = form(); bad.currency = "CNY USD"
        guard case .failure = prepareFolderBudget(bad, folder: folder) else { return XCTFail("invalid code") }
        bad = form(); bad.account = "Assets:Cash"
        guard case .failure = prepareFolderBudget(bad, folder: folder) else { return XCTFail("not a category") }
        XCTAssertEqual(try read(), source)
    }
}
