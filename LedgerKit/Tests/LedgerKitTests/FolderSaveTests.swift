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

    func testAnEntryWithACommentIsNotOffered() throws {
        let commented = "2026-10-16 * \"Sample Shop\" \"Lunch\"\n  Expenses:Food  35.00 CNY ; a comment\n  Assets:Bank  -35.00 CNY\n"
        try write("main.bean", opens + "\n" + commented)
        let (found, ledger) = try entry()
        XCTAssertNil(folderEditDraft(found, ledger, Derived(ledger)))
    }

    func testEntriesTheFullFormShowsAreOfferedAndUnchangedWriteNothing() throws {
        let split = "2026-10-16 * \"Sample Shop\" \"Lunch\"\n  Expenses:Food  30.00 CNY\n  Expenses:Food  5.00 CNY\n  Assets:Bank  -20.00 CNY\n  Assets:Cash  -15.00 CNY\n"
        let advanced = "2025-01-01 open Assets:Receivable:Reimburse CNY\n\n2026-10-16 * \"Sample Shop\" \"Lunch\" #reimbursed ^reimburse-1\n  Assets:Receivable:Reimburse  35.00 CNY\n  Assets:Bank  -35.00 CNY\n"
        for text in [split, advanced] {
            try write("main.bean", opens + "\n" + text)
            XCTAssertTrue(try prepared(try editing()).files.isEmpty, text)
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

    private let feeOpens = """
    2025-01-01 open Assets:Wallet USD,HKD
    2025-01-01 open Assets:HK HKD
    2025-01-01 open Expenses:Fee:Bank CNY,USD,HKD
    2025-01-01 open Income:Dollars USD

    2025-01-03 * "Employer" "Opening dollars"
      Assets:Wallet  100.00 USD
      Income:Dollars  -100.00 USD

    """

    func testATransferWithAFeeIsWrittenAsTheSharedFormatWould() throws {
        try write("main.bean", opens + "\n" + feeOpens)
        for (mode, charged) in [(TransferFeeMode.added, "-37.00"), (.included, "-35.00"), (.deducted, "-2.00")] {
            var new = draft(.transfer)
            new.narration = mode.rawValue
            new.transferFee = "2"; new.feeCurrency = "CNY"; new.feeMode = mode
            try commitFolderSave(try prepared(new), folder: folder)
            let added = try XCTUnwrap(try XCTUnwrap(loadLedger(folder: folder)).txns.first { $0.narration == mode.rawValue })
            XCTAssertEqual(added.postings.first { $0.account == transferFeeAccount }?.units, 2, mode.rawValue)
            XCTAssertEqual(added.postings.compactMap(\.units).reduce(0, +), 0, accuracy: 0.001, mode.rawValue)
            XCTAssertTrue(added.src.contains(charged), added.src)
        }
    }

    func testAFeePaidFromAnotherAccountNamesIt() throws {
        try write("main.bean", opens + "\n" + feeOpens)
        var new = draft(.transfer)
        new.transferFee = "2"; new.feeCurrency = "CNY"; new.feeMode = .separate; new.feeFunding = "Assets:Cash"
        try commitFolderSave(try prepared(new), folder: folder)
        let text = try read("main.bean")
        XCTAssertTrue(text.contains("fee_account: \"Assets:Cash\""), text)
    }

    func testATransferWithAFeeIsOfferedAndUnchangedWritesNothing() throws {
        let entry = """
        2026-10-16 * "Transfer" "With fee" #transfer
          fee_mode: "added"
          Assets:Bank  -37.00 CNY
          Assets:Cash  35.00 CNY
          Expenses:Fee:Bank  2.00 CNY

        """
        try write("main.bean", opens + "\n" + feeOpens + "\n" + entry)
        let before = try read("main.bean")
        var draft = try editing("With fee")
        XCTAssertEqual(draft.kind, .transfer)
        XCTAssertEqual(draft.transferFee, "2")
        XCTAssertEqual(draft.feeMode, .added)
        XCTAssertTrue(try prepared(draft).files.isEmpty)
        XCTAssertEqual(try read("main.bean"), before)
        draft.transferFee = "3"
        try commitFolderSave(try prepared(draft), folder: folder)
        let edited = try XCTUnwrap(try XCTUnwrap(loadLedger(folder: folder)).txns.first { $0.narration == "With fee" })
        XCTAssertEqual(edited.postings.first { $0.account == transferFeeAccount }?.units, 3)
        XCTAssertEqual(edited.postings.first { $0.account == "Assets:Bank" }?.units, -38)
    }

    func testAnExchangeKeepsTheBanksQuoteWhileItsAmountsStay() throws {
        let entry = """
        2026-10-16 * "Bank" "Exchange" #fx
          exchange_rate: "1 USD = 7.80000 HKD"
          Assets:Wallet  -10.00 USD
          Assets:HK  78.00 HKD @@ 10.00 USD

        """
        try write("main.bean", opens + "\n" + feeOpens + "\n" + entry)
        var draft = try editing("Exchange")
        XCTAssertEqual(draft.toAmount, "78")
        XCTAssertTrue(try prepared(draft).files.isEmpty)
        draft.narration = "Renamed"
        try commitFolderSave(try prepared(draft), folder: folder)
        XCTAssertTrue(try read("main.bean").contains("exchange_rate: \"1 USD = 7.80000 HKD\""))
    }

    func testAnExchangeWithinOneAccountIsWrittenFromTheCurrencyChosen() throws {
        try write("main.bean", opens + "\n" + feeOpens)
        var new = draft(.transfer)
        new.narration = "Within"
        new.funding = "Assets:Wallet"; new.to = "Assets:Wallet"
        new.amount = "10"; new.currency = "USD"; new.targetCurrency = "HKD"; new.toAmount = "78"
        try commitFolderSave(try prepared(new), folder: folder)
        let added = try XCTUnwrap(try XCTUnwrap(loadLedger(folder: folder)).txns.first { $0.narration == "Within" })
        XCTAssertEqual(added.postings.first { $0.currency == "HKD" }?.units, 78)
        XCTAssertTrue(added.tags.contains("fx"))
    }

    func testAnExpenseWithAFeeIsOfferedAndKeepsItsFee() throws {
        let entry = """
        2026-10-16 * "Sample Shop" "Lunch"
          fee_mode: "added"
          Expenses:Fee:Bank  1.00 CNY
          Expenses:Food  35.00 CNY
          Assets:Bank  -36.00 CNY

        """
        try write("main.bean", opens + "\n" + feeOpens + "\n" + entry)
        var draft = try editing()
        XCTAssertTrue(try prepared(draft).files.isEmpty)
        draft.narration = "Changed"
        try commitFolderSave(try prepared(draft), folder: folder)
        let edited = try XCTUnwrap(try XCTUnwrap(loadLedger(folder: folder)).txns.first { $0.narration == "Changed" })
        XCTAssertEqual(edited.postings.first { $0.account == transferFeeAccount }?.units, 1)
        XCTAssertEqual(edited.postings.first { $0.account == "Assets:Bank" }?.units, -36)
    }

    func testASplitWithSomeoneOpensTheirReceivableAndNamesThem() throws {
        var new = draft(.expense)
        new.narration = "Shared"
        new.split = true
        new.shares = [Share(person: "Alex", amount: "10")]
        try commitFolderSave(try prepared(new), folder: folder)
        let ledger = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertNotNil(ledger.accounts[personalAccount])
        let added = try XCTUnwrap(ledger.txns.first { $0.narration == "Shared" })
        let theirs = try XCTUnwrap(added.postings.first { isPersonal($0.account) })
        XCTAssertEqual(theirs.units, 10)
        XCTAssertEqual(theirs.meta["person"]?.stringValue, "Alex")
        XCTAssertEqual(added.postings.first { $0.account == "Expenses:Food" }?.units, 25)
    }

    func testSplitRowsWriteTheBalancingAmountOut() throws {
        var new = draft(.multi)
        new.narration = "Rows"
        var category = DraftRow(account: "Expenses:Food")
        category.amount = "35"
        new.rows = [category, DraftRow(account: "Assets:Bank")]
        try commitFolderSave(try prepared(new), folder: folder)
        let added = try XCTUnwrap(try XCTUnwrap(loadLedger(folder: folder)).txns.first { $0.narration == "Rows" })
        XCTAssertEqual(added.postings.first { $0.account == "Assets:Bank" }?.units, -35)
        XCTAssertTrue(try read("main.bean").contains("-35.00 CNY"))
    }

    func testTextIsAlignedAndReplacingAnAssertionIsAskedAbout() throws {
        var new = Draft()
        new.kind = .raw
        new.raw = "2026-10-16 balance Assets:Bank 1000.00 CNY"
        let first = try prepared(new)
        XCTAssertTrue(first.issues.isEmpty)
        try commitFolderSave(first, folder: folder)
        XCTAssertTrue(try read("main.bean").contains(alignText(new.raw)))
        let again = try prepared(new)
        XCTAssertEqual(again.issues.first?.detail, "2026-10-16 Assets:Bank")
        XCTAssertEqual(again.issues.first?.blocking, false)
        try commitFolderSave(again, folder: folder)
        XCTAssertEqual(try read("main.bean").components(separatedBy: " balance Assets:Bank").count, 2)
    }

    func testTheSourceSavedUnchangedWritesNothing() throws {
        let commented = "2026-10-16 * \"Sample Shop\" \"Lunch\"\n  Expenses:Food  35.00 CNY ; a comment\n  Assets:Bank  -35.00 CNY\n"
        try write("main.bean", opens + "\n" + commented)
        let before = try read("main.bean")
        let save = try prepared(folderSourceDraft(try entry().0))
        XCTAssertTrue(save.files.isEmpty)
        try commitFolderSave(save, folder: folder)
        XCTAssertEqual(try read("main.bean"), before)
    }

    func testChangingTheSourceReplacesOnlyThatEntry() throws {
        try write("main.bean", opens + "\n" + sample + "\n" + sample)
        var draft = folderSourceDraft(try entry(occurrence: 1).0)
        draft.raw = draft.raw.replacingOccurrences(of: "35.00", with: "50.00") + " ; checked"
        try commitFolderSave(try prepared(draft), folder: folder)
        let text = try read("main.bean")
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "35.00 CNY")).lowerBound, try XCTUnwrap(text.range(of: "50.00 CNY")).lowerBound)
        XCTAssertTrue(text.contains("; checked"))
        XCTAssertEqual(try XCTUnwrap(loadLedger(folder: folder)).txns.filter { $0.narration == "Lunch" }.map { $0.postings[0].units }, [35, 50])
    }

    func testASourceThatDoesNotBalanceWritesNothing() throws {
        try write("main.bean", opens + "\n" + sample)
        let before = try read("main.bean")
        var draft = folderSourceDraft(try entry().0)
        draft.raw = draft.raw.replacingOccurrences(of: "-35.00", with: "-30.00")
        guard case .failure = prepareFolderSave(draft, folder: folder) else { return XCTFail("should be refused") }
        XCTAssertEqual(try read("main.bean"), before)
    }

    func testAConfigChangeKeepsTheRestOfLedgerXJSON() throws {
        try write("ledger-x.json", "{\"receivable\": \"Assets:Receivable:Company\"}")
        try commitFolderSave(try prepareFolderConfig(folder: folder) { $0.alertsConfirmed = ["dup|a"] }.get(), folder: folder)
        let config = try XCTUnwrap(ledgerConfig(folder: folder))
        XCTAssertEqual(config.receivable, "Assets:Receivable:Company")
        XCTAssertEqual(config.alertsConfirmed, ["dup|a"])
        XCTAssertTrue(try prepareFolderConfig(folder: folder) { $0.alertsConfirmed = ["dup|a"] }.get().files.isEmpty)
    }

    func testAConfigThatDoesNotReadIsNotWrittenOver() throws {
        try write("ledger-x.json", "{ not json")
        guard case .failure = prepareFolderConfig(folder: folder, { $0.alertsConfirmed = ["x"] }) else { return XCTFail("should be refused") }
        XCTAssertEqual(try read("ledger-x.json"), "{ not json")
    }

    func testAKnownPayeeFillsOnlyWhatIsBlank() throws {
        try write("main.bean", opens + "\n" + sample)
        let derived = Derived(try XCTUnwrap(loadLedger(folder: folder)))
        var new = Draft()
        new.funding = "Assets:Cash"
        let filled = applyingPayee(new, name: "Sample Shop", derived, onlyBlanks: true)
        XCTAssertEqual(filled.account, "Expenses:Food")
        XCTAssertEqual(filled.funding, "Assets:Cash")
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

    func testACurrencyCheckCommodityAsksForIsDeclared() throws {
        try write("main.bean", "plugin \"beancount.plugins.check_commodity\"\n\n" + opens)
        // the error holds its entry weakly: the ledger stays while it's read
        let before = try XCTUnwrap(loadLedger(folder: folder))
        let error = try XCTUnwrap(before.errors.first { $0.fix == .declareCommodity("CNY") })
        try commitFolderSave(try prepareFolderCommodity("CNY", firstUsed: error.entry?.date, folder: folder).get(), folder: folder)
        let after = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertEqual(after.entries.filter { $0.type == .commodity }.map { "\($0.date) \($0.currency ?? "")" }, ["2025-01-01 CNY"])
        XCTAssertTrue(after.errors.isEmpty, "\(after.errors.map(\.msg))")
    }

    func testAStatementGoesToTheInstitutionsFolderWithALineForIt() throws {
        let pdf = Data("%PDF-1.4 sample".utf8)
        try commitFolderSave(try prepareFolderStatement(account: "Assets:Bank", date: "2026-10-31", data: pdf, ext: "PDF", folder: folder).get(), folder: folder)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("documents/bank/bank_20261031.pdf")), pdf)
        let second = try prepareFolderStatement(account: "Assets:Bank", date: "2026-10-31", data: pdf, ext: "pdf", folder: folder).get()
        try commitFolderSave(second, folder: folder)
        let ledger = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertEqual(documentItems(ledger).map(\.path), ["documents/bank/bank_20261031_1.pdf", "documents/bank/bank_20261031.pdf"])
        XCTAssertEqual(documentItems(ledger).map(\.isAttachment), [false, false])
        XCTAssertTrue(ledger.errors.isEmpty, "\(ledger.errors.map(\.msg))")
    }

    func testAnAttachmentLinksTheEntryAndIsFiledUnderTheAccountThatPaid() throws {
        try write("main.bean", opens + "\n" + sample)
        let (found, _) = try entry("Lunch")
        let jpg = Data([0xFF, 0xD8, 0xFF])
        try commitFolderSave(try prepareFolderAttachment(found, data: jpg, ext: "jpg", folder: folder).get(), folder: folder)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("documents/receipts/receipts_20261016.jpg")), jpg)
        let ledger = try XCTUnwrap(loadLedger(folder: folder))
        let item = try XCTUnwrap(documentItems(ledger).first)
        XCTAssertEqual(item.account, "Assets:Bank")
        XCTAssertEqual(item.transaction?.narration, "Lunch")
        let link = try XCTUnwrap(item.transaction?.links.first { $0.hasPrefix("doc-20261016-") })
        XCTAssertEqual(item.entry.links, [link])
        // a second one shares the entry's link and leaves the entry as it is
        let (again, _) = try entry("Lunch")
        let before = try read("main.bean").components(separatedBy: "\n").filter { $0.contains("Lunch") }
        try commitFolderSave(try prepareFolderAttachment(again, data: jpg, ext: "jpg", folder: folder).get(), folder: folder)
        let after = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertEqual(documentItems(after).filter { $0.entry.links == [link] }.count, 2)
        XCTAssertEqual(try read("main.bean").components(separatedBy: "\n").filter { $0.contains("Lunch") }, before)
    }

    func testAFileAlreadyThereIsNotWrittenOver() throws {
        let save = try prepareFolderStatement(account: "Assets:Bank", date: "2026-10-31", data: Data("new".utf8), ext: "pdf", folder: folder).get()
        try write("documents/bank/bank_20261031.pdf", "old")
        XCTAssertThrowsError(try commitFolderSave(save, folder: folder))
        XCTAssertEqual(try read("documents/bank/bank_20261031.pdf"), "old")
        XCTAssertFalse(try read("main.bean").contains("document"))
    }

    func testDeletingAStatementKeepsItsFileOrPutsItInTheTrash() throws {
        let pdf = Data("%PDF".utf8)
        for day in ["2026-10-30", "2026-10-31"] {
            try commitFolderSave(try prepareFolderStatement(account: "Assets:Bank", date: day, data: pdf, ext: "pdf", folder: folder).get(), folder: folder)
        }
        func statement(_ name: String) throws -> Entry {
            try XCTUnwrap(documentItems(try XCTUnwrap(loadLedger(folder: folder))).first { $0.name == name }?.entry)
        }
        XCTAssertEqual(try deleteFolderDocument(try statement("bank_20261030.pdf"), file: false, folder: folder), .kept)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("documents/bank/bank_20261030.pdf").path))
        XCTAssertEqual(try deleteFolderDocument(try statement("bank_20261031.pdf"), file: true, folder: folder), .trashed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("documents/bank/bank_20261031.pdf").path))
        XCTAssertTrue(documentItems(try XCTUnwrap(loadLedger(folder: folder))).isEmpty)
    }

    func testAFileAnotherLineStillPointsAtStays() throws {
        try write("documents/bank/shared.pdf", "%PDF")
        try write("main.bean", opens + """

        2026-10-30 document Assets:Bank "documents/bank/shared.pdf"
        2026-10-31 document Assets:Cash "documents/bank/shared.pdf"

        """)
        let first = try XCTUnwrap(documentItems(try XCTUnwrap(loadLedger(folder: folder))).last?.entry)
        XCTAssertEqual(try deleteFolderDocument(first, file: true, folder: folder), .inUse(1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("documents/bank/shared.pdf").path))
        XCTAssertEqual(documentItems(try XCTUnwrap(loadLedger(folder: folder))).map(\.account), ["Assets:Cash"])
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

    func testAnAdvanceGoesToTheAccountLedgerXJsonNames() throws {
        var config = LedgerXConfig()
        config.receivable = "Assets:Receivable:Company"
        try write(LedgerXConfig.path, String(decoding: try JSONEncoder().encode(config), as: UTF8.self))
        try write("main.bean", opens + "\n2025-01-01 open Assets:Receivable:Company CNY\n")
        var advance = draft(.expense)
        advance.reimb = true
        try commitFolderSave(try prepared(advance), folder: folder)
        XCTAssertTrue(try read("main.bean").contains("Assets:Receivable:Company"))

        let (found, ledger) = try entry("Sample")
        let reopened = try XCTUnwrap(folderEditDraft(found, ledger, folderDerived(ledger, config: ledgerConfig(folder: folder))))
        XCTAssertEqual(reopened.kind, .expense)
        XCTAssertTrue(reopened.reimb)
        XCTAssertEqual(reopened.account, "Expenses:Food")
    }

    func testAFolderWithoutALedgerIsRefused() throws {
        try FileManager.default.removeItem(at: folder.appendingPathComponent("main.bean"))
        guard case .failure = prepareFolderSave(draft(.expense), folder: folder) else { return XCTFail("should be refused") }
    }
}
