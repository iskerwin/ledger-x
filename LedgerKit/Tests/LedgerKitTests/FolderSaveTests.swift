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

    private let sample = """
    2026-10-16 * "Sample Shop" "Lunch"
      Expenses:Food  35.00 CNY
      Assets:Bank  -35.00 CNY

    """

    private func entry(_ narration: String = "Lunch", occurrence: Int = 0) throws -> (Entry, Ledger) {
        let ledger = try XCTUnwrap(loadLedger(folder: folder))
        return (ledger.txns.filter { $0.narration == narration }[occurrence], ledger)
    }

    private func editing(_ narration: String = "Lunch", occurrence: Int = 0) throws -> Draft {
        let (found, ledger) = try entry(narration, occurrence: occurrence)
        return try XCTUnwrap(folderEditDraft(found, ledger, Derived(ledger)))
    }

    func testEditingChangesTheEntryInPlaceAndLeavesTheRest() throws {
        try write("main.bean", opens + "\n" + sample + "\n2026-10-17 * \"Other\"\n  Expenses:Food  1.00 CNY\n  Assets:Bank  -1.00 CNY\n")
        var draft = try editing()
        draft.amount = "50"
        try commitFolderSave(try prepared(draft), folder: folder)
        let text = try read("main.bean")
        XCTAssertFalse(text.contains("35.00"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "50.00 CNY")).lowerBound, try XCTUnwrap(text.range(of: "\"Other\"")).lowerBound)
        let after = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertEqual(after.txns.filter { $0.narration == "Lunch" }.count, 1)
        XCTAssertEqual(after.txns.count, 3)
    }

    func testSavingAnEntryUnchangedWritesNothing() throws {
        try write("main.bean", opens + "\n" + sample)
        let before = try read("main.bean")
        let save = try prepared(try editing())
        XCTAssertTrue(save.files.isEmpty)
        try commitFolderSave(save, folder: folder)
        XCTAssertEqual(try read("main.bean"), before)
    }

    func testChangingTheYearMovesTheEntryAndWritesTheNewPlaceFirst() throws {
        try write("main.bean", "include \"journals/2026.bean\"\n" + opens)
        try write("journals/2026.bean", sample)
        var draft = try editing()
        draft.date = "2027-01-05"
        let save = try prepared(draft)
        XCTAssertEqual(save.files.map(\.path), ["journals/2027.bean", "main.bean", "journals/2026.bean"])
        try commitFolderSave(save, folder: folder)
        XCTAssertFalse(try read("journals/2026.bean").contains("Lunch"))
        XCTAssertTrue(try read("journals/2027.bean").contains("Lunch"))
        XCTAssertEqual(try XCTUnwrap(loadLedger(folder: folder)).txns.filter { $0.narration == "Lunch" }.map(\.date), ["2027-01-05"])
    }

    func testOfTwoIdenticalEntriesOnlyTheChosenOneChanges() throws {
        try write("main.bean", opens + "\n" + sample + "\n" + sample)
        var draft = try editing(occurrence: 1)
        draft.amount = "50"
        try commitFolderSave(try prepared(draft), folder: folder)
        let text = try read("main.bean")
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "35.00 CNY")).lowerBound, try XCTUnwrap(text.range(of: "50.00 CNY")).lowerBound)
        XCTAssertEqual(try XCTUnwrap(loadLedger(folder: folder)).txns.filter { $0.narration == "Lunch" }.count, 2)
    }

    func testIdenticalEntriesThatMovedAreNotGuessedAt() throws {
        try write("main.bean", opens + "\n" + sample + "\n" + sample)
        var draft = try editing()
        draft.amount = "50"
        let moved = "; a new first line\n" + (try read("main.bean"))
        try write("main.bean", moved)
        guard case .failure = prepareFolderSave(draft, folder: folder) else { return XCTFail("should be refused") }
        XCTAssertEqual(try read("main.bean"), moved)
    }

    func testAnEntryChangedElsewhereIsNotEdited() throws {
        try write("main.bean", opens + "\n" + sample)
        var draft = try editing()
        draft.amount = "50"
        let changed = (try read("main.bean")).replacingOccurrences(of: "35.00", with: "36.00")
        try write("main.bean", changed)
        guard case .failure = prepareFolderSave(draft, folder: folder) else { return XCTFail("should be refused") }
        XCTAssertEqual(try read("main.bean"), changed)
    }

    func testEntriesTheSheetCantShowAreNotOffered() throws {
        let commented = "2026-10-16 * \"Sample Shop\" \"Lunch\"\n  Expenses:Food  35.00 CNY ; a comment\n  Assets:Bank  -35.00 CNY\n"
        let split = "2026-10-16 * \"Sample Shop\" \"Lunch\"\n  Expenses:Food  30.00 CNY\n  Expenses:Food  5.00 CNY\n  Assets:Bank  -20.00 CNY\n  Assets:Cash  -15.00 CNY\n"
        let advanced = "2025-01-01 open Assets:Receivable:Reimburse CNY\n\n2026-10-16 * \"Sample Shop\" \"Lunch\" #reimbursed ^reimburse-1\n  Assets:Receivable:Reimburse  35.00 CNY\n  Assets:Bank  -35.00 CNY\n"
        for text in [commented, split, advanced] {
            try write("main.bean", opens + "\n" + text)
            let (found, ledger) = try entry()
            XCTAssertNil(folderEditDraft(found, ledger, Derived(ledger)), text)
        }
    }

    func testDeletingRemovesOnlyThatEntry() throws {
        try write("main.bean", opens + "\n" + sample + "\n" + sample)
        let (found, _) = try entry(occurrence: 1)
        try commitFolderSave(try prepareFolderDelete(found, folder: folder).get(), folder: folder)
        let after = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertEqual(after.txns.filter { $0.narration == "Lunch" }.count, 1)
        XCTAssertLessThan(try XCTUnwrap(after.txns.first { $0.narration == "Lunch" }).line, found.line)
    }

    private let purchase = """
    2026-10-16 * "Sample Shop" "Lunch" ^refund-1
      Expenses:Food  35.00 CNY
      Assets:Bank  -35.00 CNY

    """

    private let refund = """
    2026-10-17 * "Sample Shop" "Lunch back" #refund ^refund-1
      Expenses:Food  -35.00 CNY
      Assets:Bank  35.00 CNY

    """

    func testEditingALinkedEntryKeepsItsLinkAndLeavesTheOtherAlone() throws {
        try write("main.bean", opens + "\n" + purchase + "\n" + refund)
        var draft = try editing()
        draft.amount = "50"
        try commitFolderSave(try prepared(draft), folder: folder)
        let after = try XCTUnwrap(loadLedger(folder: folder))
        let edited = try XCTUnwrap(after.txns.first { $0.narration == "Lunch" })
        XCTAssertEqual(edited.links, ["refund-1"])
        XCTAssertEqual(edited.postings.first { $0.account == "Expenses:Food" }?.units, 50)
        let other = try XCTUnwrap(after.txns.first { $0.narration == "Lunch back" })
        XCTAssertEqual(other.links, ["refund-1"])
        XCTAssertEqual(other.postings.first { $0.account == "Expenses:Food" }?.units, -35)
    }

    func testAnUnchangedLinkedEntryWritesNothing() throws {
        try write("main.bean", opens + "\n" + purchase + "\n" + refund)
        XCTAssertTrue(try prepared(try editing()).files.isEmpty)
    }

    func testEditingARefundKeepsWhatMakesItOne() throws {
        try write("main.bean", opens + "\n" + purchase + "\n" + refund)
        let (found, ledger) = try entry("Lunch back")
        var draft = try XCTUnwrap(folderEditDraft(found, ledger, Derived(ledger)))
        XCTAssertEqual(draft.kind, .refund)
        XCTAssertEqual(draft.amount, "35")
        draft.narration = "Changed"
        try commitFolderSave(try prepared(draft), folder: folder)
        let edited = try XCTUnwrap(try XCTUnwrap(loadLedger(folder: folder)).txns.first { $0.narration == "Changed" })
        XCTAssertEqual(edited.links, ["refund-1"])
        XCTAssertTrue(edited.tags.contains("refund"))
        XCTAssertEqual(edited.postings.first { $0.account == "Expenses:Food" }?.units, -35)
    }

    func testDeletingOneOfAPairTakesTheLinkOffTheOther() throws {
        try write("main.bean", opens + "\n" + purchase + "\n" + refund)
        let (found, _) = try entry("Lunch back")
        try commitFolderSave(try prepareFolderDelete(found, folder: folder).get(), folder: folder)
        let after = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertNil(after.txns.first { $0.narration == "Lunch back" })
        XCTAssertEqual(try XCTUnwrap(after.txns.first { $0.narration == "Lunch" }).links, [])
    }

    func testThePairCanBeInTwoFiles() throws {
        try write("main.bean", "include \"journals/2026.bean\"\ninclude \"journals/2027.bean\"\n" + opens)
        try write("journals/2026.bean", purchase)
        try write("journals/2027.bean", refund.replacingOccurrences(of: "2026-10-17", with: "2027-01-05"))
        let (found, _) = try entry("Lunch back")
        try commitFolderSave(try prepareFolderDelete(found, folder: folder).get(), folder: folder)
        XCTAssertFalse(try read("journals/2026.bean").contains("^refund-1"))
        XCTAssertFalse(try read("journals/2027.bean").contains("Lunch back"))
    }

    func testALinkSharedBySeveralStaysOnTheOthers() throws {
        let second = refund.replacingOccurrences(of: "Lunch back", with: "Lunch back again").replacingOccurrences(of: "2026-10-17", with: "2026-10-18")
        try write("main.bean", opens + "\n" + purchase + "\n" + refund + "\n" + second)
        let (found, _) = try entry("Lunch back")
        try commitFolderSave(try prepareFolderDelete(found, folder: folder).get(), folder: folder)
        let after = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertEqual(try XCTUnwrap(after.txns.first { $0.narration == "Lunch" }).links, ["refund-1"])
        XCTAssertEqual(try XCTUnwrap(after.txns.first { $0.narration == "Lunch back again" }).links, ["refund-1"])
    }

    func testAnotherKindOfLinkIsLeftOnTheOtherEntry() throws {
        let one = sample.replacingOccurrences(of: "\"Lunch\"", with: "\"Lunch\" ^sub-sample")
        let two = one.replacingOccurrences(of: "2026-10-16", with: "2026-10-17").replacingOccurrences(of: "\"Lunch\"", with: "\"Dinner\"")
        try write("main.bean", opens + "\n" + one + "\n" + two)
        let (found, _) = try entry()
        try commitFolderSave(try prepareFolderDelete(found, folder: folder).get(), folder: folder)
        XCTAssertEqual(try XCTUnwrap(try XCTUnwrap(loadLedger(folder: folder)).txns.first { $0.narration == "Dinner" }).links, ["sub-sample"])
    }

    func testDeletingThatBreaksAnAssertionIsReportedBeforeWriting() throws {
        let start = opens + "\n" + sample + "\n2026-12-31 balance Assets:Bank 965.00 CNY\n"
        try write("main.bean", start)
        let (found, _) = try entry()
        XCTAssertTrue(try prepareFolderDelete(found, folder: folder).get().issues.contains { $0.kind == .balance })
        XCTAssertEqual(try read("main.bean"), start)
    }

    private func prepareBalance(_ amount: Double, day: String = "2026-10-16") -> Result<FolderSave, FolderSaveError> {
        prepareFolderBalance(account: "Assets:Bank", day: day, amount: amount, currency: "CNY", folder: folder)
    }

    func testABalanceThatAgreesIsAssertedForTheNextMorning() throws {
        try write("main.bean", opens + "\n" + sample)
        try commitFolderSave(try prepareBalance(965).get(), folder: folder)
        XCTAssertTrue(try read("main.bean").contains(balanceLine("2026-10-17", "Assets:Bank", 965, "CNY")))
        let result = try XCTUnwrap(try XCTUnwrap(loadLedger(folder: folder)).balanceResults.first)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.entry.date, "2026-10-17")
    }

    func testEntriesOnTheDayItselfCount() throws {
        try write("main.bean", opens + "\n" + sample)
        XCTAssertNoThrow(try prepareBalance(1000, day: "2026-10-15").get())
        guard case .failure = prepareBalance(1000) else { return XCTFail("the day's own entry should count") }
    }

    func testABalanceThatDiffersIsRefusedWithTheDifference() throws {
        try write("main.bean", opens + "\n" + sample)
        let before = try read("main.bean")
        guard case .failure(let error) = prepareBalance(960) else { return XCTFail("should be refused") }
        XCTAssertTrue(error.message.contains("965"), error.message)
        XCTAssertEqual(try read("main.bean"), before)
    }

    func testASecondAssertionForTheSameDayIsRefused() throws {
        let start = opens + "\n" + sample + "\n" + balanceLine("2026-10-17", "Assets:Bank", 965, "CNY") + "\n"
        try write("main.bean", start)
        guard case .failure = prepareBalance(965) else { return XCTFail("should be refused") }
        XCTAssertEqual(try read("main.bean"), start)
    }

    func testAFolderWithoutALedgerIsRefused() throws {
        try FileManager.default.removeItem(at: folder.appendingPathComponent("main.bean"))
        guard case .failure = prepareFolderSave(draft(.expense), folder: folder) else { return XCTFail("should be refused") }
    }
}
