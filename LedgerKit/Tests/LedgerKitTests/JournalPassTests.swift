import XCTest
@testable import LedgerKit

/// Journal totals from Derived, and a search remembered by the ledger, match classifying and filtering by hand.
/// Another currency, an account left out of net worth, and the day "今天" means are all in the fixture.
final class JournalPassTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger {
        let L = loadLedger(root: "main.bean") { _ in text }
        XCTAssertTrue(L.errors.isEmpty, L.errors.map(\.msg).joined(separator: "\n"))
        return L
    }

    private let text = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank CNY
    2026-01-01 open Assets:Cash USD
    2026-01-01 open Assets:Hidden CNY
    2026-01-01 open Equity:Opening
    2026-01-01 open Income:Salary
    2026-01-01 open Income:Rewards
    2026-01-01 open Expenses:Food
    2026-01-01 open Expenses:Travel

    2026-02-01 price USD 7.00 CNY

    2026-03-01 * "工资"
      Assets:Bank  1000.00 CNY
      Income:Salary

    2026-03-02 * "超市" "退货"
      Expenses:Food  -5.00 CNY
      Assets:Bank

    2026-03-03 * "超市" "买菜"
      Expenses:Food  20.00 CNY
      Assets:Bank

    2026-03-04 * "超市" "优惠"
      Expenses:Food  20.00 CNY
      Income:Rewards  -2.00 CNY
      Assets:Bank

    2026-03-05 * "转账"
      Assets:Hidden  100.00 CNY
      Assets:Bank

    2026-03-12 * "机票"
      Expenses:Travel  10.00 USD
      Assets:Cash

    2026-03-14 * "零食"
      Expenses:Food  8.00 CNY
      Assets:Hidden

    2026-03-15 * "甲"
      Expenses:Food  10.00 CNY
      Assets:Bank

    2026-03-16 * "明天"
      Expenses:Food  50.00 CNY
      Assets:Bank

    """

    private func byHand(_ ts: [Entry], _ L: Ledger) -> (Double, Double) {
        var out = 0.0, inn = 0.0
        for t in ts {
            let c = classify(t, L)
            switch c.kind {
            case .expense, .refund: out -= c.amount
            case .income: inn += c.amount
            default: break
            }
        }
        return (out, inn)
    }

    func testTotalsMatchClassifyInTheJournalsOrder() {
        let L = ledger(text)
        let d = Derived(L, today: "2026-03-15")
        let newestFirst = Array(L.txns.reversed())
        let summed = d.journalTotals(newestFirst)
        let hand = byHand(newestFirst, L)
        XCTAssertEqual(summed.spent, hand.0, accuracy: 1e-6)
        XCTAssertEqual(summed.income, hand.1, accuracy: 1e-6)
        // 退货减少支出；优惠只算支出 20，收入的 2 不进收入合计；转账两边都不算
        let one = { (payee: String) -> (Double, Double) in
            let t = L.txns.filter { $0.payee == payee }
            return d.journalTotals(t)
        }
        XCTAssertEqual(one("超市").spent, -5 + 20 + 20, accuracy: 1e-6)
        XCTAssertEqual(one("超市").income, 0, accuracy: 1e-6)
        XCTAssertEqual(one("工资").income, 1000, accuracy: 1e-6)
        XCTAssertEqual(one("转账").spent, 0, accuracy: 1e-6)
        XCTAssertEqual(one("机票").spent, 70, accuracy: 1e-6)
        // 不计入净资产的 Hidden 付出的 8 元仍在支出合计里
        XCTAssertEqual(one("零食").spent, 8, accuracy: 1e-6)
        let all = netWorthSeries(L, today: "2026-03-15")
        let left = netWorthSeries(L, today: "2026-03-15", exclude: ["Assets:Hidden"])
        XCTAssertNotEqual(all.last?.netWorth, left.last?.netWorth)
        XCTAssertEqual(d.journalTotals(L.txns).spent, byHand(L.txns, L).0, accuracy: 1e-6)
    }

    func testSearchIsRememberedAndTodayMovesTheBoundary() {
        let L = ledger(text)
        let saved = TxQuery.today
        defer { TxQuery.today = saved }
        TxQuery.today = { "2026-03-15" }
        let today = filterTransactions(L, account: nil, query: "今天")
        let again = filterTransactions(L, account: nil, query: "今天")
        XCTAssertEqual(today.map(\.id), again.map(\.id))
        XCTAssertEqual(today.map(\.payee), ["甲"])
        // 本月是整个 3 月，含 16 日；近 2 天停在 14 日和 15 日
        XCTAssertTrue(filterTransactions(L, account: nil, query: "本月").contains { $0.payee == "明天" })
        let recent = filterTransactions(L, account: nil, query: "近2天").map(\.date)
        XCTAssertEqual(Set(recent), ["2026-03-14", "2026-03-15"])
        TxQuery.today = { "2026-03-16" }
        XCTAssertEqual(filterTransactions(L, account: nil, query: "今天").map(\.payee), ["明天"])
        // 换一天之后，15 日的「今天」不再被拿来用
        XCTAssertFalse(filterTransactions(L, account: nil, query: "今天").contains { $0.payee == "甲" })
        let hidden = filterTransactions(L, account: "Assets:Hidden", query: "")
        XCTAssertEqual(Set(hidden.map(\.payee)), ["转账", "零食"])
        let food = filterTransactions(L, account: "Expenses:Food", query: "超市")
        XCTAssertTrue(food.allSatisfy { $0.payee == "超市" })
        XCTAssertEqual(food.count, 3)
    }
}
