import XCTest
@testable import LedgerKit

final class AccountFormTests: XCTestCase {
    private var folder: URL!
    private let source = """
    2025-01-01 open Assets:Bank CNY,USD ; keep header comment
      name: "Sample bank"
      institution: "Example"
      ; keep this comment
    2025-01-01 open Income:Salary CNY
    2025-01-01 open Expenses:Food CNY

    2025-01-02 * "Example employer" "Pay"
      Assets:Bank 100.00 CNY
      Income:Salary -100.00 CNY

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
    private func opened(_ account: String = "Assets:Bank") throws -> Entry {
        try XCTUnwrap(try ledger().entries.first { $0.type == .open && $0.account == account })
    }

    func testCreateUsesConfiguredAccountFileAndIncludesIt() throws {
        var config = LedgerXConfig()
        config.files["accounts"] = "accounts/open.bean"
        try config.json().write(to: folder.appendingPathComponent(LedgerXConfig.path), atomically: true, encoding: .utf8)
        var form = AccountForm(account: "Assets:Cash", date: "2025-01-01")
        form.currencies = "cny, USD"
        form.name = "Sample cash"
        form.allowNegative = true
        form.statementDay = 15
        let save = try prepareFolderAccount(form, replacing: nil, folder: folder).get()
        XCTAssertEqual(save.issues, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("accounts/open.bean").path))
        try commitFolderSave(save, folder: folder)
        XCTAssertTrue(try read().contains("include \"accounts/open.bean\""))
        let account = try XCTUnwrap(try ledger().accounts["Assets:Cash"])
        XCTAssertEqual(account.currencies, ["CNY", "USD"])
        XCTAssertEqual(account.meta["name"]?.stringValue, "Sample cash")
        XCTAssertEqual(AccountForm(account, fallbackDate: "2026-01-01"), formWithCurrencies(form, "CNY,USD"))
    }

    private func formWithCurrencies(_ form: AccountForm, _ codes: String) -> AccountForm {
        var result = form
        result.currencies = codes
        return result
    }

    func testEditingPreservesUnknownMetadataCommentsAndTransactions() throws {
        let original = try opened()
        var form = AccountForm(try XCTUnwrap(try ledger().accounts["Assets:Bank"]), fallbackDate: "2025-01-01")
        form.name = "Renamed display"
        form.statementDay = 10
        let save = try prepareFolderAccount(form, replacing: original, folder: folder).get()
        XCTAssertEqual(save.issues, [])
        try commitFolderSave(save, folder: folder)
        let text = try read()
        XCTAssertTrue(text.contains("institution: \"Example\""))
        XCTAssertTrue(text.contains("; keep this comment"))
        XCTAssertTrue(text.contains("; keep header comment"))
        XCTAssertTrue(text.contains("name: \"Renamed display\""))
        XCTAssertEqual(try ledger().txns.count, 1)
        XCTAssertEqual(try ledger().entries.filter { $0.type == .open && $0.account == "Assets:Bank" }.count, 1)
    }

    func testCurrencySpecificCreditLimitSurvivesEditingAndRoundTrip() throws {
        try write(source + "\n2025-01-01 open Liabilities:Card CNY,USD\n  credit_limit: \"50000 USD\"\n  statement_day: 3\n  due_day: 20\n")
        let account = try XCTUnwrap(try ledger().accounts["Liabilities:Card"])
        var form = AccountForm(account, fallbackDate: "2025-01-01")
        form.name = "Sample card"
        try commitFolderSave(try prepareFolderAccount(form, replacing: opened("Liabilities:Card"), folder: folder).get(), folder: folder)
        let after = try XCTUnwrap(try ledger().accounts["Liabilities:Card"])
        XCTAssertEqual(creditLimit(after.meta[creditLimitKey], "USD"), 50000)
        XCTAssertNil(creditLimit(after.meta[creditLimitKey], "CNY"))
        XCTAssertEqual(AccountForm(after, fallbackDate: "2026-01-01"), form)
    }

    func testInvalidFieldsAndDuplicateAccountCannotWrite() throws {
        for (name, limit, codes) in [("Invalid", "", "CNY"), ("Assets:Bank", "", "CNY"),
                                    ("Liabilities:Card", "abc", "CNY"), ("Liabilities:Card", "nan", "CNY"),
                                    ("Liabilities:Card", "-1", "CNY"), ("Liabilities:Card", "10 cny", "CNY"),
                                    ("Assets:Cash", "", "CNY,CNY")] {
            var form = AccountForm(account: name, date: "2025-01-01")
            form.limit = limit
            form.currencies = codes
            guard case .failure = prepareFolderAccount(form, replacing: nil, folder: folder) else { return XCTFail(name + " " + limit + " " + codes) }
        }
        XCTAssertEqual(try read(), source)
    }

    func testAnExistingImplicitAccountCanBeDeclared() throws {
        try write(source + "\n2025-01-03 * \"Sample\"\n  Expenses:New 1.00 CNY\n  Assets:Bank -1.00 CNY\n")
        let form = AccountForm(account: "Expenses:New", date: "2025-01-01")
        let save = try prepareFolderAccount(form, replacing: nil, folder: folder).get()
        XCTAssertEqual(save.issues, [])
        try commitFolderSave(save, folder: folder)
        XCTAssertEqual(try ledger().accounts["Expenses:New"]?.implicit, false)
    }

    func testStaleOpenAndRenameThroughEditAreRefused() throws {
        let original = try opened()
        var form = AccountForm(account: "Assets:Bank", date: "2025-01-01")
        form.name = "Changed"
        try write(source.replacingOccurrences(of: "Sample bank", with: "External edit"))
        guard case .failure = prepareFolderAccount(form, replacing: original, folder: folder) else { return XCTFail("stale edit") }
        guard case .failure = prepareFolderClose(original, date: "2025-01-10", folder: folder) else { return XCTFail("stale close") }
        form.account = "Assets:Other"
        guard case .failure = prepareFolderAccount(form, replacing: original, folder: folder) else { return XCTFail("rename") }
        XCTAssertTrue(try read().contains("External edit"))
    }

    func testChangingCurrencyOrOpenDateReportsBlockingMisuse() throws {
        let original = try opened()
        for (date, codes) in [("2025-01-01", "USD"), ("2025-01-03", "CNY")] {
            var form = AccountForm(account: "Assets:Bank", date: date)
            form.currencies = codes
            let result = prepareFolderAccount(form, replacing: original, folder: folder)
            if case .success(let save) = result { XCTAssertTrue(save.issues.contains(where: \.blocking)) }
        }
        XCTAssertEqual(try read(), source)
    }

    func testCloseChecksLaterTransactionsAndReopenKeepsHistory() throws {
        let original = try opened()
        let premature = prepareFolderClose(original, date: "2025-01-01", folder: folder)
        if case .success(let save) = premature { XCTAssertTrue(save.issues.contains(where: \.blocking)) }
        let save = try prepareFolderClose(original, date: "2025-01-10", folder: folder).get()
        XCTAssertEqual(save.issues, [])
        try commitFolderSave(save, folder: folder)
        XCTAssertEqual(try ledger().accounts["Assets:Bank"]?.close, "2025-01-10")
        guard case .failure = prepareFolderClose(original, date: "2025-01-11", folder: folder) else { return XCTFail("duplicate close") }
        let closed = try XCTUnwrap(try ledger().entries.first { $0.type == .close })
        try commitFolderSave(try prepareFolderDelete(closed, folder: folder).get(), folder: folder)
        XCTAssertNil(try ledger().accounts["Assets:Bank"]?.close)
        XCTAssertEqual(try ledger().txns.count, 1)
    }

    func testPreparedAccountDoesNotOverwriteLaterFileChange() throws {
        let form = AccountForm(account: "Assets:Cash", date: "2025-01-01")
        let save = try prepareFolderAccount(form, replacing: nil, folder: folder).get()
        try write(source + "\n; external edit\n")
        XCTAssertThrowsError(try commitFolderSave(save, folder: folder))
        XCTAssertNil(try ledger().accounts["Assets:Cash"])
    }

    func testInvalidDatesAndInjectedDirectivesAreRefused() throws {
        for date in ["2025-02-30", "2025-13-01", "2025-01-01\n2025-01-01 open Assets:Other"] {
            let form = AccountForm(account: "Assets:Cash", date: date)
            guard case .failure = prepareFolderAccount(form, replacing: nil, folder: folder) else { return XCTFail(date) }
            guard case .failure = prepareFolderClose(try opened(), date: date, folder: folder) else { return XCTFail(date) }
        }
        guard case .failure = prepareFolderClose(try opened(), date: "2024-12-31", folder: folder) else { return XCTFail("close before open") }
        XCTAssertEqual(try read(), source)
    }

    func testChangedOpeningDateKeepsFileChronological() throws {
        var form = AccountForm(account: "Assets:Bank", date: "2024-12-01")
        form.currencies = "CNY,USD"
        let save = try prepareFolderAccount(form, replacing: opened(), folder: folder).get()
        XCTAssertEqual(save.issues, [])
        try commitFolderSave(save, folder: folder)
        let entries = parseFile(try read(), file: "main.bean").entries
        XCTAssertEqual(entries.map(\.date), entries.map(\.date).sorted())
        XCTAssertEqual(try ledger().accounts["Assets:Bank"]?.open, "2024-12-01")
    }
}
