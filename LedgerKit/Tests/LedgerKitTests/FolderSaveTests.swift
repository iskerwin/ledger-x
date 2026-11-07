import XCTest
@testable import LedgerKit

final class FolderSaveTests: XCTestCase {
    private var folder: URL!
    private let opens = """
    2025-01-01 open Assets:Bank CNY
    2025-01-01 open Assets:Cash CNY
    2025-01-01 open Expenses:Food CNY
    2025-01-01 open Income:Salary CNY

    2025-01-02 * "Employer" "Opening pay"
      Assets:Bank  1000.00 CNY
      Income:Salary  -1000.00 CNY

    """

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("main.bean", opens)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
    }

    private func draft(_ kind: DraftKind, date: String = "2026-10-16", amount: String = "35") -> Draft {
        var draft = Draft()
        draft.kind = kind
        draft.date = date
        draft.payee = "Sample Shop"
        draft.narration = "Sample"
        draft.amount = amount
        draft.currency = "CNY"
        draft.funding = "Assets:Bank"
        switch kind {
        case .income: draft.account = "Income:Salary"
        case .transfer: draft.to = "Assets:Cash"
        default: draft.account = "Expenses:Food"
        }
        return draft
    }

    private func prepared(_ draft: Draft) throws -> FolderSave {
        try prepareFolderSave(draft, folder: folder).get()
    }

    func testEachKindIsWrittenAsTheSharedFormatWouldAndReadsBack() throws {
        for (kind, expected) in [(DraftKind.expense, TxKind.expense), (.income, .income), (.transfer, .transfer)] {
            var new = draft(kind)
            new.narration = kind.rawValue
            let before = try XCTUnwrap(loadLedger(folder: folder))
            let text = draftText(new, before, Derived(before)).trimmingCharacters(in: .whitespacesAndNewlines)
            let save = try prepared(new)
            XCTAssertEqual(save.issues, [], "\(kind)")
            try commitFolderSave(save, folder: folder)
            XCTAssertTrue(try read("main.bean").contains(text), "\(kind)")
            let after = try XCTUnwrap(loadLedger(folder: folder))
            XCTAssertEqual(after.txns.count, before.txns.count + 1, "\(kind)")
            let added = try XCTUnwrap(after.txns.first { $0.narration == kind.rawValue })
            XCTAssertEqual(classify(added, after).kind, expected)
            XCTAssertEqual(after.errors.filter { !$0.soft }.map(\.msg), [])
        }
    }

    func testTheEntryGoesToTheYearsJournalAndANewFileIsIncluded() throws {
        try write("main.bean", "include \"journals/2026.bean\"\n" + opens)
        try write("journals/2026.bean", "2026-01-01 * \"Sample\"\n  Assets:Bank  -1.00 CNY\n  Expenses:Food  1.00 CNY\n")
        try commitFolderSave(try prepared(draft(.expense, date: "2027-01-05")), folder: folder)
        XCTAssertTrue(try read("journals/2027.bean").contains("Sample Shop"))
        XCTAssertTrue(try read("main.bean").contains("journals/2027.bean"))
        XCTAssertEqual(try XCTUnwrap(loadLedger(folder: folder)).txns.filter { $0.date == "2027-01-05" }.count, 1)
    }

    func testAnEntryWithAProblemWritesNothing() throws {
        let before = try read("main.bean")
        for bad in [draft(.expense, amount: ""), draft(.expense, amount: "0")] {
            guard case .failure = prepareFolderSave(bad, folder: folder) else { return XCTFail("should be refused") }
        }
        XCTAssertEqual(try read("main.bean"), before)
    }

    func testAFailingBalanceAssertionIsReportedBeforeWriting() throws {
        let start = opens + "\n2026-12-31 balance Assets:Bank 1000.00 CNY\n"
        try write("main.bean", start)
        let save = try prepared(draft(.expense))
        XCTAssertTrue(save.issues.contains { $0.kind == .balance })
        XCTAssertEqual(try read("main.bean"), start)
    }

    func testAFileChangedAfterPreparingIsNotOverwritten() throws {
        let save = try prepared(draft(.expense))
        let elsewhere = opens + "\n; changed elsewhere\n"
        try write("main.bean", elsewhere)
        XCTAssertThrowsError(try commitFolderSave(save, folder: folder))
        XCTAssertEqual(try read("main.bean"), elsewhere)
    }

    func testAFolderWithoutALedgerIsRefused() throws {
        try FileManager.default.removeItem(at: folder.appendingPathComponent("main.bean"))
        guard case .failure = prepareFolderSave(draft(.expense), folder: folder) else { return XCTFail("should be refused") }
    }
}
