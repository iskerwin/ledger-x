import XCTest
@testable import LedgerKit

/// credit-card cycles and the cash-flow forecast
final class PlanTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private let base = """
    option "operating_currency" "CNY"
    2025-01-01 open Assets:Bank:CMB CNY
    2025-01-01 open Liabilities:CreditCard:CMB CNY
      statement_day: 5
      due_day: 23
      credit_limit: 20000
    2025-01-01 open Liabilities:CreditCard:BOC CNY
    2025-01-01 open Expenses:Food CNY
    2025-01-01 open Expenses:Housing:Rent CNY
    2025-01-01 open Expenses:Subscription CNY
    2025-01-01 open Income:Salary CNY
    2025-01-01 open Equity:Opening CNY

    2025-01-02 * "Opening"
      Assets:Bank:CMB  20000.00 CNY
      Equity:Opening

    """

    func testDayHelpers() {
        XCTAssertEqual(dayIn("2026-02", 31), "2026-02-28")
        XCTAssertEqual(statementOn(orBefore: "2026-10-09", day: 5), "2026-10-05")
        XCTAssertEqual(statementOn(orBefore: "2026-10-04", day: 5), "2026-09-05")
        XCTAssertEqual(statementOn(orAfter: "2026-10-06", day: 5), "2026-11-05")
        XCTAssertEqual(statementOn(orBefore: "2026-03-01", day: 31), "2026-02-28")
        XCTAssertEqual(dueDate(statement: "2026-10-05", statementDay: 5, dueDay: 23).0, "2026-10-23")
        XCTAssertEqual(dueDate(statement: "2026-10-25", statementDay: 25, dueDay: 13).0, "2026-11-13")
        XCTAssertEqual(dueDate(statement: "2026-10-05", statementDay: 5, dueDay: nil).0, "2026-10-25")
    }

    func testCardCycle() throws {
        let t = base + """
        2026-09-10 * "Shop"
          Expenses:Food  1000.00 CNY
          Liabilities:CreditCard:CMB
        2026-10-05 * "On statement day"
          Expenses:Food  200.00 CNY
          Liabilities:CreditCard:CMB
        2026-10-06 * "Next cycle"
          Expenses:Food  50.00 CNY
          Liabilities:CreditCard:CMB
        2026-10-08 * "Repay"
          Liabilities:CreditCard:CMB  700.00 CNY
          Assets:Bank:CMB

        """
        let L = ledger(t)
        XCTAssertTrue(L.errors.isEmpty, L.errors.map { $0.msg }.joined(separator: "; "))
        let cs = cardCycles(L, today: "2026-10-09")
        XCTAssertEqual(cs.map { $0.account }, ["Liabilities:CreditCard:CMB"])     // BOC has no statement_day
        let c = try XCTUnwrap(cs.first)
        XCTAssertEqual(c.statement, "2026-10-05")
        XCTAssertEqual(c.previousStatement, "2026-09-05")
        XCTAssertEqual(c.nextStatement, "2026-11-05")
        XCTAssertEqual(c.due, "2026-10-23")
        XCTAssertEqual(c.statementAmount, 1200)
        XCTAssertEqual(c.paid, 700)
        XCTAssertEqual(c.remaining, 500)
        XCTAssertEqual(c.unbilled, 50)
        XCTAssertEqual(c.balance, 550)
        XCTAssertEqual(c.available ?? 0, 19450, accuracy: 0.001)
        XCTAssertFalse(c.overdue(today: "2026-10-09"))
        XCTAssertTrue(c.overdue(today: "2026-10-24"))
        XCTAssertEqual(usualRepaymentAccount("Liabilities:CreditCard:CMB", L), "Assets:Bank:CMB")
        // the repayment text balances
        let text = repaymentText(card: c.account, from: "Assets:Bank:CMB", amount: 500, currency: "CNY", date: "2026-10-09")
        XCTAssertTrue(checkText(text, L).ok, text)
        let paid = ledger(t + "\n" + text + "\n")
        XCTAssertTrue(cardCycles(paid, today: "2026-10-09").first?.settled ?? false)
    }

    func testForecast() throws {
        var t = base
        // salary on the 10th, rent on the 1st, for six months
        for m in 4...9 {
            t += "2026-0\(m)-10 * \"ACME\" \"工资\"\n  Assets:Bank:CMB  15000.00 CNY\n  Income:Salary\n"
            t += "2026-0\(m)-01 * \"房东\" \"房租\"\n  Expenses:Housing:Rent  5000.00 CNY\n  Assets:Bank:CMB\n"
            t += "2026-0\(m)-15 * \"超市\" \"日常\"\n  Expenses:Food  900.00 CNY\n  Assets:Bank:CMB\n"
        }
        t += """
        2026-09-20 * "Shop"
          Expenses:Food  3000.00 CNY
          Liabilities:CreditCard:CMB
        2026-01-12 custom "subscription" "iCloud+" "monthly" 21.00 CNY
          account: "Expenses:Subscription"
          funding: "Assets:Bank:CMB"

        """
        let L = ledger(t)
        XCTAssertTrue(L.errors.isEmpty, L.errors.map { $0.msg }.joined(separator: "; "))
        let series = recurringSeries(L, today: "2026-10-01")
        XCTAssertTrue(series.contains { $0.payee == "ACME" && $0.income && $0.period == .monthly })
        XCTAssertTrue(series.contains { $0.payee == "房东" && !$0.income })
        XCTAssertEqual(spendableAccounts(L, today: "2026-10-01"), ["Assets:Bank:CMB"])

        let f = forecast(L, today: "2026-10-01", days: 60, includeDaily: false)
        XCTAssertEqual(f.points.count, 61)
        // salary on 10-10 and 11-10, rent on 11-01 (10-01 is today), iCloud on 10-12 and 11-12, the card bill on 10-23
        XCTAssertEqual(f.events.filter { $0.kind == .income }.map { $0.date }, ["2026-10-10", "2026-11-10"])
        XCTAssertEqual(f.events.filter { $0.title == "房东" }.map { $0.date }, ["2026-11-01"])
        XCTAssertEqual(f.events.filter { $0.kind == .subscription }.map { $0.date }, ["2026-10-12", "2026-11-12"])
        // the 09-20 purchase is on the bill closing 10-05 (due 10-23), plus the average spending until then
        let bill = try XCTUnwrap(f.events.first { $0.kind == .card && $0.date == "2026-10-23" })
        XCTAssertEqual(bill.amount, -(3000 + 3000.0 / 90 * 4), accuracy: 0.02)
        let sum = f.events.reduce(0) { $0 + $1.amount }
        XCTAssertEqual(f.end, f.start + sum, accuracy: 0.01)
        XCTAssertTrue(f.cardsWithoutCycle.contains("Liabilities:CreditCard:BOC"))

        // the supermarket (900 every month) is a series, so the everyday average leaves it out
        let g = forecast(L, today: "2026-10-01", days: 30, includeDaily: true)
        XCTAssertEqual(g.dailySpend, 0, accuracy: 0.01)
        // money running out is found
        let poor = forecast(ledger(t + "2026-09-30 * \"Car\"\n  Expenses:Food  100000.00 CNY\n  Assets:Bank:CMB\n"), today: "2026-10-01", days: 30, includeDaily: false)
        XCTAssertNotNil(poor.firstBelow(0))
    }
}
