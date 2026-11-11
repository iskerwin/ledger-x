import XCTest
@testable import LedgerKit

/// a journal line's figures, worked out once for the ledger: what it shows for each kind of entry, newest first
final class JournalRowTests: XCTestCase {
    private let L = loadLedger(root: "main.bean") { _ in """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank CNY
    2026-01-01 open Assets:Savings CNY
    2026-01-01 open Assets:Receivable:Personal CNY
    2026-01-01 open Liabilities:Card CNY
    2026-01-01 open Expenses:Food CNY,HKD
    2026-01-01 open Expenses:Fee:Bank CNY
    2026-01-01 open Income:Salary CNY

    2026-03-01 * "星巴克" "咖啡"
      Expenses:Food  38.00 CNY
      Liabilities:Card  -38.00 CNY

    2026-03-02 * "工资"
      Income:Salary  -18000.00 CNY
      Assets:Bank  18000.00 CNY

    2026-03-03 * "还款" #transfer
      Liabilities:Card  500.00 CNY
      Assets:Bank  -500.00 CNY

    2026-03-04 * "转账" "跨行" #transfer
      Expenses:Fee:Bank  2.00 CNY
      Assets:Bank  -102.00 CNY
      Assets:Savings  100.00 CNY

    2026-03-05 ! "港铁" #trip
      Expenses:Food  50.00 HKD @ 0.90 CNY
      Liabilities:Card  -45.00 CNY

    2026-03-06 * "聚餐"
      Expenses:Food  100.00 CNY
      Assets:Receivable:Personal  100.00 CNY
        person: "王五"
      Liabilities:Card  -200.00 CNY
    """ }

    private func row(_ payee: String, account: String? = nil) throws -> JournalRow {
        try XCTUnwrap(journalRows(L, account: account).first { $0.entry.payee == payee })
    }

    func testNewestWrittenComesFirst() {
        XCTAssertEqual(journalRows(L).map(\.entry.payee), ["聚餐", "港铁", "转账", "还款", "工资", "星巴克"])
    }

    func testSpendingShowsWhatWentOutAndTheNoteUnderThePayee() throws {
        let coffee = try row("星巴克")
        XCTAssertEqual(coffee.amounts, [ShownAmount(amount: -38, currency: "CNY", tone: .loss)])
        XCTAssertEqual(coffee.amounts.first?.text, "-¥38.00")
        XCTAssertEqual(coffee.note, "咖啡")
        XCTAssertEqual(coffee.kind, .expense)
        XCTAssertTrue(coffee.charged.isEmpty)
        XCTAssertFalse(coffee.marked)
        // no narration: nothing under the payee
        XCTAssertEqual(try row("工资").note, "")
        XCTAssertEqual(try row("工资").amounts, [ShownAmount(amount: 18000, currency: "CNY", tone: .gain)])
    }

    func testTransferShowsWhatMovedWithoutASign() throws {
        let paid = try row("还款")
        XCTAssertEqual(paid.amounts, [ShownAmount(amount: 500, currency: "CNY", tone: .neutral)])
        XCTAssertEqual(paid.amounts.first?.text, "¥500.00")
        XCTAssertEqual(paid.category, "转账")
        XCTAssertFalse(paid.marked)
    }

    func testTransferWithAFeeShowsWhatMovedAndTheFee() throws {
        let sent = try row("转账")
        XCTAssertEqual(sent.amounts, [ShownAmount(amount: 100, currency: "CNY", tone: .neutral), ShownAmount(amount: -2, currency: "CNY", tone: .loss)])
        XCTAssertTrue(sent.charged.isEmpty)
    }

    func testSpendingInAnotherCurrencyShowsWhatTheCardWasCharged() throws {
        let fare = try row("港铁")
        XCTAssertEqual(fare.amounts, [ShownAmount(amount: -50, currency: "HKD", tone: .loss)])
        XCTAssertEqual(fare.charged, [ShownAmount(amount: -45, currency: "CNY", tone: .neutral)])
        // 待确认 and a tag of its own
        XCTAssertTrue(fare.marked)
    }

    func testAccountsNameWhoThePersonalLinesAreWith() throws {
        XCTAssertTrue(try row("聚餐").accounts.hasSuffix(" · 王五"))
    }

    func testThroughAnAccountShowsWhatMovedInIt() throws {
        XCTAssertEqual(try row("星巴克", account: "Liabilities:Card").amounts, [ShownAmount(amount: -38, currency: "CNY", tone: .loss)])
        XCTAssertEqual(try row("还款", account: "Liabilities:Card").amounts, [ShownAmount(amount: 500, currency: "CNY", tone: .gain)])
        XCTAssertTrue(try row("港铁", account: "Liabilities:Card").charged.isEmpty)
        // only what moved money in it
        XCTAssertEqual(journalRows(L, account: "Liabilities:Card").map(\.entry.payee), ["聚餐", "港铁", "还款", "星巴克"])
        // the parent account takes in its sub-accounts
        XCTAssertEqual(try row("聚餐", account: "Assets:Receivable").amounts, [ShownAmount(amount: 100, currency: "CNY", tone: .gain)])
    }

    func testHiddenAmountsApplyWhenDrawnNotWhenWorkedOut() throws {
        let coffee = try row("星巴克")
        KitPrivacy.masked = true
        defer { KitPrivacy.masked = false }
        XCTAssertEqual(coffee.amounts.first?.text, "¥***")
    }
}
