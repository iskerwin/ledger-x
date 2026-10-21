import XCTest
@testable import LedgerKit

final class ExpenseFeeTests: XCTestCase {
    private func environment() -> (Ledger, Derived) {
        let L = loadLedger { _ in """
        option "operating_currency" "HKD"
        2025-01-01 open Assets:Bank:Example HKD
        2025-01-01 open Assets:Bank:Other USD
        2025-01-01 open Expenses:Shopping GBP,HKD
        2025-01-01 open Expenses:Fee:Bank GBP,HKD,USD
        """ }
        return (L, Derived(L))
    }

    private func expense() -> Draft {
        var d = Draft()
        d.kind = .expense; d.date = "2025-02-01"
        d.payee = "Example supplier"; d.narration = "Test purchase"
        d.account = "Expenses:Shopping"; d.funding = "Assets:Bank:Example"
        d.amount = "10"; d.currency = "GBP"; d.targetCurrency = "HKD"
        d.byRate = true; d.rate = "9.00000"
        d.transferFee = "1"; d.feeCurrency = "GBP"; d.feeMode = .added
        return d
    }

    private func checked(_ d: Draft, _ L: Ledger, _ D: Derived) throws -> Entry {
        XCTAssertNil(draftIssue(d, L, D))
        let result = validateText(draftText(d, L, D), L, single: true)
        XCTAssertTrue(result.ok, result.msg ?? "")
        return try XCTUnwrap(result.txn)
    }

    private func roundTrip(_ t: Entry, _ L: Ledger, _ D: Derived) throws -> Draft {
        let edited = try XCTUnwrap(editDraft(t, L, D))
        XCTAssertEqual(edited.kind, .expense)
        XCTAssertTrue(sameTxn(t, try checked(edited, L, D)))
        let copied = draftFromTxn(t, L, D, defaultFunding: nil)
        XCTAssertEqual(copied.transferFee, edited.transferFee)
        XCTAssertTrue(sameTxn(t, try checked(copied, L, D)))
        let split = try convertingEditor(edited, to: .multi, ledger: L, derived: D).get()
        let raw = try convertingEditor(split, to: .raw, ledger: L, derived: D).get()
        let back = try convertingEditor(raw, to: .expense, ledger: L, derived: D).get()
        XCTAssertTrue(sameTxn(t, try checked(back, L, D)))
        return edited
    }

    func testBillCurrencyFeeUsesPurchaseRateAndAddsToActualDebitOnce() throws {
        let (L, D) = environment(); let d = expense()
        let t = try checked(d, L, D)
        let fee = try XCTUnwrap(t.postings.first { $0.account == transferFeeAccount })
        XCTAssertEqual(t.postings.first?.account, transferFeeAccount)
        XCTAssertEqual(fee.units, 1); XCTAssertEqual(fee.currency, "GBP")
        XCTAssertEqual(fee.price?.number, 9); XCTAssertEqual(fee.price?.currency, "HKD")
        XCTAssertEqual(t.postings.filter { $0.account == d.funding }.reduce(0) { $0 + ($1.units ?? 0) }, -99)
        XCTAssertTrue(draftText(d, L, D).contains("@ 9.00000 HKD"))
        let b = try XCTUnwrap(expenseFeeBreakdown(d, L, D))
        XCTAssertEqual(b.purchaseDebit, 90); XCTAssertEqual(b.feeDebit, 9); XCTAssertEqual(b.totalDebit, 99)
        _ = try roundTrip(t, L, D)
    }

    func testFeeInPaymentCurrencyDoesNotChangePurchaseAmountOrRate() throws {
        let (L, D) = environment(); var d = expense()
        d.transferFee = "0.5"; d.feeCurrency = "HKD"
        let t = try checked(d, L, D)
        XCTAssertEqual(t.postings.first { $0.account == d.account }?.units, 10)
        XCTAssertEqual(t.postings.first { $0.account == d.account }?.price?.number, 9)
        XCTAssertEqual(t.postings.first { $0.account == d.funding }?.units, -90.5)
        let back = try roundTrip(t, L, D)
        XCTAssertEqual(back.feeCurrency, "HKD")
    }

    func testSeparateThirdCurrencyFeeAndExactPaidTotalRoundTrip() throws {
        let (L, D) = environment(); var d = expense()
        d.byRate = false; d.rate = ""; d.paid = "90.03"
        d.transferFee = "2"; d.feeCurrency = "USD"; d.feeMode = .separate
        d.feeFunding = "Assets:Bank:Other"
        let t = try checked(d, L, D)
        XCTAssertEqual(t.postings.first { $0.account == d.funding }?.units, -90.03)
        XCTAssertEqual(t.postings.first { $0.account == d.feeFunding }?.units, -2)
        let back = try roundTrip(t, L, D)
        XCTAssertEqual(back.feeFunding, d.feeFunding)
        XCTAssertEqual(back.feeMode, .separate)
        let b = try XCTUnwrap(expenseFeeBreakdown(d, L, D))
        XCTAssertEqual(b.totalDebit, 90.03); XCTAssertEqual(b.debitCurrency, "USD")
    }

    func testSameCurrencyFeeAndBlankFeeDoNotChangeLegacyExpense() throws {
        let (L, D) = environment(); var d = expense()
        d.currency = "HKD"; d.transferFee = "2"; d.feeCurrency = "HKD"
        let t = try checked(d, L, D)
        XCTAssertEqual(t.postings.first { $0.account == d.funding }?.units, -12)
        _ = try roundTrip(t, L, D)
        d.transferFee = nil
        let plain = try checked(d, L, D)
        XCTAssertEqual(plain.postings.count, 2)
        XCTAssertFalse(draftText(d, L, D).contains("fee_mode"))
    }

    func testInvalidFeesAndUnsupportedComplexExpensesAreRejected() {
        let (L, D) = environment(); var d = expense()
        for text in ["-1", "1+", "nan"] {
            d.transferFee = text
            XCTAssertEqual(draftIssue(d, L, D)?.field, .fee)
            XCTAssertTrue(draftText(d, L, D).isEmpty)
        }
        d.transferFee = "1"; d.feeMode = .included
        XCTAssertEqual(draftIssue(d, L, D)?.field, .fee)
        d.feeMode = .deducted
        XCTAssertEqual(draftIssue(d, L, D)?.field, .fee)
        d.feeMode = .added; d.feeCurrency = "USD"
        XCTAssertEqual(draftIssue(d, L, D)?.field, .fee)
        d.feeMode = .separate; d.feeFunding = d.funding
        XCTAssertEqual(draftIssue(d, L, D)?.field, .fee)
        d.feeMode = .added; d.feeCurrency = "GBP"; d.reimb = true
        XCTAssertEqual(draftIssue(d, L, D)?.field, .fee)
    }

    func testRefundDoesNotAutomaticallyRefundBankFee() throws {
        let (L, D) = environment(); let d = expense()
        let t = try checked(d, L, D)
        let refund = refundDraft(t, L, D, defaultFunding: nil)
        XCTAssertEqual(refund.kind, .refund); XCTAssertEqual(refund.amount, "10")
        XCTAssertNil(refund.transferFee)
        let refunded = try checked(refund, L, D)
        XCTAssertFalse(refunded.postings.contains { $0.account == transferFeeAccount })
    }

    func testPreciseExpenseQuoteSurvivesFeeGeneration() throws {
        let (L, D) = environment(); var d = expense()
        d.rate = "9.12345678"; d.amount = "1000"; d.transferFee = "0.5"
        let text = draftText(d, L, D)
        XCTAssertTrue(text.contains("@ 9.12345678 HKD"))
        let t = try checked(d, L, D)
        let b = try XCTUnwrap(expenseFeeBreakdown(d, L, D))
        XCTAssertEqual(b.purchaseDebit, 9123.46)
        XCTAssertEqual(b.totalDebit, 9128.02)
        _ = try roundTrip(t, L, D)
    }
}
