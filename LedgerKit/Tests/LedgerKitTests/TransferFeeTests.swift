import XCTest
@testable import LedgerKit

final class TransferFeeTests: XCTestCase {
    private func environment() -> (Ledger, Derived) {
        let L = loadLedger { _ in """
        option "operating_currency" "HKD"
        2025-01-01 open Assets:Bank:Example HKD,GBP,USD
        2025-01-01 open Assets:Bank:Other HKD,GBP
        2025-01-01 open Expenses:Shopping HKD,GBP
        2025-01-01 open Expenses:Fee:Bank HKD,GBP,USD
        """ }
        return (L, Derived(L))
    }

    private func draft() -> Draft {
        var d = Draft()
        d.kind = .transfer; d.date = "2025-02-01"
        d.funding = "Assets:Bank:Example"; d.to = "Assets:Bank:Other"
        d.currency = "HKD"; d.targetCurrency = "HKD"; d.amount = "100"
        d.transferFee = "2"; d.feeCurrency = "HKD"
        return d
    }

    func testSameCurrencyFeeAddsToSourceAndComesFirst() throws {
        let (L, D) = environment(); let d = draft()
        XCTAssertNil(draftIssue(d, L, D))
        let checked = validateText(draftText(d, L, D), L)
        XCTAssertTrue(checked.ok, checked.msg ?? "")
        let t = try XCTUnwrap(checked.txn)
        XCTAssertEqual(t.postings.map { $0.account }, [transferFeeAccount, d.to, d.funding])
        XCTAssertEqual(t.postings.map { $0.units ?? 0 }, [2, 100, -102])
        let back = try XCTUnwrap(editDraft(t, L, D))
        XCTAssertEqual(back.kind, .transfer)
        XCTAssertEqual(back.amount, "100"); XCTAssertEqual(back.transferFee, "2")
        XCTAssertTrue(sameTxn(t, try XCTUnwrap(validateText(draftText(back, L, D), L).txn)))
    }

    func testSameAccountExchangePreservesReverseQuoteAndPrincipal() throws {
        let (L, D) = environment()
        var d = draft(); d.to = d.funding; d.targetCurrency = "GBP"
        d.toAmount = "10"; d.fxRate = KeptRate(text: "1 GBP = 10.0000 HKD", amount: 100, toAmount: 10)
        XCTAssertNil(draftIssue(d, L, D))
        let text = draftText(d, L, D)
        XCTAssertTrue(text.contains("\"HKD <-> GBP\""))
        XCTAssertTrue(text.contains("#fx")); XCTAssertTrue(text.contains("@@ 100.00 HKD"))
        XCTAssertTrue(text.contains("exchange_rate: \"1 GBP = 10.0000 HKD\""))
        let t = try XCTUnwrap(validateText(text, L).txn)
        let back = try XCTUnwrap(editDraft(t, L, D))
        XCTAssertEqual(back.kind, .transfer); XCTAssertEqual(back.amount, "100")
        XCTAssertEqual(back.targetCurrency, "GBP"); XCTAssertEqual(back.transferFee, "2")
        XCTAssertEqual(back.fxRate?.text, d.fxRate?.text)
        XCTAssertTrue(sameTxn(t, try XCTUnwrap(validateText(draftText(back, L, D), L).txn)))
        backToSplitAndText(back, L, D)
    }

    private func backToSplitAndText(_ d: Draft, _ L: Ledger, _ D: Derived) {
        do {
            let split = try convertingEditor(d, to: .multi, ledger: L, derived: D).get()
            let raw = try convertingEditor(split, to: .raw, ledger: L, derived: D).get()
            let back = try convertingEditor(raw, to: .transfer, ledger: L, derived: D).get()
            XCTAssertEqual(back.transferFee, d.transferFee)
            XCTAssertEqual(back.targetCurrency, d.targetCurrency)
            XCTAssertEqual(back.feeMode, d.feeMode)
            XCTAssertEqual(back.feeFunding, d.feeFunding)
        } catch { XCTFail("Exchange editor conversion: \(error)") }
    }

    func testFeeInAnotherHeldCurrencyUsesSeparateSourcePosting() throws {
        let (L, D) = environment()
        var d = draft(); d.targetCurrency = "GBP"; d.toAmount = "10"; d.feeCurrency = "GBP"
        let checked = validateText(draftText(d, L, D), L)
        XCTAssertTrue(checked.ok, checked.msg ?? "")
        let t = try XCTUnwrap(checked.txn)
        XCTAssertTrue(t.postings.contains { $0.account == d.funding && $0.currency == "GBP" && $0.units == -2 })
        let back = try XCTUnwrap(editDraft(t, L, D))
        XCTAssertEqual(back.amount, "100"); XCTAssertEqual(back.feeCurrency, "GBP")
    }

    func testInvalidCurrencyFeeAndSameCurrencySameAccountAreRejected() {
        let (L, D) = environment()
        var d = draft(); d.transferFee = "-1"
        XCTAssertEqual(draftIssue(d, L, D)?.field, .fee)
        d.transferFee = "1+"; XCTAssertEqual(draftIssue(d, L, D)?.field, .fee)
        d.transferFee = "2"; d.feeCurrency = "CNY"
        XCTAssertEqual(draftIssue(d, L, D)?.field, .fee)
        d.feeCurrency = "HKD"; d.targetCurrency = "USD"
        XCTAssertEqual(draftIssue(d, L, D)?.field, .toAmount)
        d.targetCurrency = "HKD"; d.to = d.funding
        XCTAssertEqual(draftIssue(d, L, D)?.field, .toAmount)
    }

    func testOptionalFieldsDecodeOlderDraftAndTargetCurrencyDrivesForeignPayment() throws {
        let (L, D) = environment()
        var d = Draft(); d.date = "2025-02-01"; d.amount = "10"; d.currency = "GBP"
        d.account = "Expenses:Shopping"; d.funding = "Assets:Bank:Example"
        d.targetCurrency = "HKD"; d.byRate = true; d.rate = "10"
        let checked = validateText(draftText(d, L, D), L)
        XCTAssertTrue(checked.ok, checked.msg ?? "")
        XCTAssertTrue(checked.txn?.postings.contains { $0.account == d.funding && $0.currency == "HKD" && $0.units == -100 } == true)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(d)) as! [String: Any]
        for key in ["targetCurrency", "transferFee", "feeCurrency"] { json.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(Draft.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.targetCurrency); XCTAssertNil(restored.transferFee); XCTAssertNil(restored.feeCurrency)
    }
    func testIncludedFeeUsesNetPrincipalAndPreservesBankQuote() throws {
        let (L, D) = environment()
        var d = draft(); d.to = d.funding; d.targetCurrency = "GBP"
        d.amount = "80"; d.transferFee = "0.2"; d.toAmount = "10"
        d.feeMode = .included
        d.fxRate = KeptRate(text: "1 HKD = 0.125310 GBP", amount: 80, toAmount: 10)
        let text = draftText(d, L, D)
        XCTAssertTrue(text.contains("@@ 79.80 HKD"))
        XCTAssertTrue(text.contains("exchange_rate: \"1 HKD = 0.125310 GBP\""))
        let t = try XCTUnwrap(validateText(text, L).txn)
        XCTAssertTrue(validateText(text, L).ok)
        XCTAssertTrue(t.postings.contains { $0.units == -80 && $0.currency == "HKD" })
        let back = try XCTUnwrap(editDraft(t, L, D))
        XCTAssertEqual(back.amount, "80"); XCTAssertEqual(back.toAmount, "10")
        XCTAssertEqual(back.feeMode, .included)
        XCTAssertEqual(back.fxRate?.text, d.fxRate?.text)
        backToSplitAndText(back, L, D)
        let copied = draftFromTxn(t, L, D, defaultFunding: nil)
        XCTAssertEqual(copied.feeMode, .included)
        XCTAssertEqual(copied.amount, "80")
    }

    func testTargetFeeUsesGrossExchangeAndNetReceipt() throws {
        let (L, D) = environment()
        var d = draft(); d.targetCurrency = "GBP"; d.toAmount = "9.8"
        d.transferFee = "0.2"; d.feeCurrency = "GBP"; d.feeMode = .deducted
        let checked = validateText(draftText(d, L, D), L)
        XCTAssertTrue(checked.ok, checked.msg ?? "")
        let t = try XCTUnwrap(checked.txn)
        XCTAssertEqual(t.postings.filter { $0.account == d.to && $0.currency == "GBP" }.reduce(0) { $0 + ($1.units ?? 0) }, 9.8, accuracy: 0.000001)
        let back = try XCTUnwrap(editDraft(t, L, D))
        XCTAssertEqual(back.toAmount, "9.8"); XCTAssertEqual(back.feeMode, .deducted)
        backToSplitAndText(back, L, D)
    }

    func testSeparateFeeAccountIsRestoredAndDoesNotChangePrincipal() throws {
        let (L, D) = environment()
        var d = draft(); d.to = d.funding; d.targetCurrency = "GBP"; d.toAmount = "10"
        d.feeMode = .separate; d.feeFunding = "Assets:Bank:Other"
        let checked = validateText(draftText(d, L, D), L)
        XCTAssertTrue(checked.ok, checked.msg ?? "")
        let t = try XCTUnwrap(checked.txn)
        XCTAssertTrue(t.postings.contains { $0.account == "Assets:Bank:Other" && $0.units == -2 })
        let back = try XCTUnwrap(editDraft(t, L, D))
        XCTAssertEqual(back.feeFunding, d.feeFunding); XCTAssertEqual(back.feeMode, .separate)
        XCTAssertEqual(back.amount, "100")
        backToSplitAndText(back, L, D)
    }

    func testFeeAwareRateSolverWorksInBothDirections() {
        var d = draft(); d.feeMode = .included; d.transferFee = "0.2"
        XCTAssertEqual(solveTransferRate(.converted, draft: d, amount: 80, rate: 0.12531, received: nil), 10)
        XCTAssertEqual(solveTransferRate(.amount, draft: d, amount: nil, rate: 0.12531, received: 10), 80)
        d.feeMode = .deducted
        XCTAssertEqual(solveTransferRate(.converted, draft: d, amount: 100, rate: 0.1, received: nil), 9.8)
        XCTAssertEqual(solveTransferRate(.amount, draft: d, amount: nil, rate: 0.1, received: 9.8), 100)
        XCTAssertEqual(solveTransferRate(.rate, draft: d, amount: 100, rate: nil, received: 9.8), 0.1)
    }

    func testImpossibleIncludedFeeAndWrongDeductionCurrencyAreRejected() {
        let (L, D) = environment()
        var d = draft(); d.feeMode = .included; d.transferFee = "100"
        XCTAssertEqual(draftIssue(d, L, D)?.field, .fee)
        d.transferFee = "2"; d.feeCurrency = "GBP"
        XCTAssertEqual(draftIssue(d, L, D)?.field, .fee)
        d.feeMode = .separate; d.feeFunding = ""
        XCTAssertEqual(draftIssue(d, L, D)?.field, .fee)
        d.feeFunding = "Assets:Bank:Other"; d.feeCurrency = "USD"
        XCTAssertEqual(draftIssue(d, L, D)?.field, .fee)
    }

}
