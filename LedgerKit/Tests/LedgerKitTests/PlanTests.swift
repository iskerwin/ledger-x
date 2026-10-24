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
        // 700 paid is more than the minimum (10% of 1200 by default): past the due date it is not overdue
        XCTAssertEqual(c.minimum, 120)
        XCTAssertTrue(c.minimumEstimated)
        XCTAssertEqual(c.status(today: "2026-10-24"), .minimumPaid)
        XCTAssertFalse(c.overdue(today: "2026-10-24"))
        XCTAssertEqual(usualRepaymentAccount("Liabilities:CreditCard:CMB", L), "Assets:Bank:CMB")
        // the repayment text balances
        let text = repaymentText(card: c.account, from: "Assets:Bank:CMB", amount: 500, currency: "CNY", date: "2026-10-09")
        XCTAssertTrue(checkText(text, L).ok, text)
        let paid = ledger(t + "\n" + text + "\n")
        XCTAssertTrue(cardCycles(paid, today: "2026-10-09").first?.settled ?? false)
    }

    /// the minimum payment: estimated, from min_payment_rate, or the bank's figures in a card-bill directive
    func testCardMinimum() throws {
        let spent = """
        2026-09-10 * "Shop"
          Expenses:Food  1000.00 CNY
          Liabilities:CreditCard:CMB

        """
        // nothing paid: due, then overdue
        var c = try XCTUnwrap(cardCycles(ledger(base + spent), today: "2026-10-09").first)
        XCTAssertEqual(c.status(today: "2026-10-09"), .due)
        XCTAssertEqual(c.status(today: "2026-10-24"), .overdue)
        XCTAssertEqual(c.minimumRemaining, 100)

        // less than the minimum is still overdue after the due date
        let little = spent + """
        2026-10-20 * "Repay"
          Liabilities:CreditCard:CMB  50.00 CNY
          Assets:Bank:CMB

        """
        c = try XCTUnwrap(cardCycles(ledger(base + little), today: "2026-10-24").first)
        XCTAssertEqual(c.minimumRemaining, 50)
        XCTAssertEqual(c.status(today: "2026-10-24"), .overdue)

        // a lower rate on the open: 5% (written as "5%")
        let rated = base.replacingOccurrences(of: "  credit_limit: 20000", with: "  credit_limit: 20000\n  min_payment_rate: \"5%\"")
        c = try XCTUnwrap(cardCycles(ledger(rated + little), today: "2026-10-24").first)
        XCTAssertEqual(c.minimum, 50)
        XCTAssertEqual(c.status(today: "2026-10-24"), .minimumPaid)
        XCTAssertEqual(minPaymentRate(.number(0.05)), 0.05)
        XCTAssertEqual(minPaymentRate(.number(5)), 0.05)
        XCTAssertEqual(minPaymentRate(nil), defaultMinPaymentRate)

        // the bank's figures (an instalment: the ledger owes 1000, the bill is 300 with 30 minimum)
        let bill = cardBillText(card: "Liabilities:CreditCard:CMB", statement: "2026-10-05", amount: 300, minimum: 30, currency: "CNY")
        XCTAssertEqual(bill, "2026-10-05 custom \"card-bill\" Liabilities:CreditCard:CMB 300.00 CNY 30.00 CNY")
        let L = ledger(base + little + bill + "\n")
        XCTAssertTrue(L.errors.isEmpty, L.errors.map { $0.msg }.joined(separator: "; "))
        c = try XCTUnwrap(cardCycles(L, today: "2026-10-24").first)
        XCTAssertEqual(c.statementAmount, 300)
        XCTAssertEqual(c.minimum, 30)
        XCTAssertFalse(c.minimumEstimated)
        XCTAssertNotNil(c.bill)
        XCTAssertEqual(c.remaining, 250)
        XCTAssertEqual(c.status(today: "2026-10-24"), .minimumPaid)
        // a bill for an earlier statement does not apply to this one
        c = try XCTUnwrap(cardCycles(L, today: "2026-11-06").first)
        XCTAssertNil(c.bill)
        XCTAssertEqual(c.statement, "2026-11-05")
        XCTAssertEqual(cardBills(L).map { $0.minimum }, [30])
    }

    /// Two payments that look alike (one payee, one day, one amount, from one account, to two categories) are two
    /// payments in the forecast; they were kept as one
    func testForecastKeepsLookAlikePayments() {
        var t = base + "2025-01-01 open Expenses:Housing:Fee CNY\n2025-01-01 open Expenses:Car:Parking CNY\n"
        for m in 6...9 {
            t += "2026-0\(m)-05 * \"物业\" \"物业费\"\n  Expenses:Housing:Fee  300.00 CNY\n  Assets:Bank:CMB\n"
            t += "2026-0\(m)-05 * \"物业\" \"停车费\"\n  Expenses:Car:Parking  300.00 CNY\n  Assets:Bank:CMB\n"
        }
        let L = ledger(t)
        XCTAssertTrue(L.errors.isEmpty, L.errors.map { $0.msg }.joined(separator: "; "))
        let f = forecast(L, today: "2026-10-01", days: 30, includeDaily: false)
        let fees = f.events.filter { $0.title == "物业" }
        XCTAssertEqual(fees.map(\.date), ["2026-10-05", "2026-10-05"])
        XCTAssertEqual(Set(f.events.map(\.id)).count, f.events.count)
        XCTAssertEqual(f.end, f.start + f.events.reduce(0) { $0 + $1.amount }, accuracy: 0.01)
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

    func testForecastSalaryFromPayslip() {
        // a payslip of several items: the money into the bank counts, and the template gives the usual month
        let t = base + """
        2025-01-01 open Income:Salary:Base CNY
        2025-01-01 open Income:Salary:Allowance CNY
        2025-01-01 open Assets:Receivable:Employer

        2026-08-24 * "星河" "2026-07 工资" ^salary-xinghe-202607
          Income:Salary:Base  -2080.00 CNY
          Income:Salary:Allowance  -500.00 CNY
          Assets:Receivable:Employer  500.00 CNY
          Assets:Bank:CMB  2080.00 CNY

        2026-09-24 * "星河" "2026-08 工资" ^salary-xinghe-202608
          Income:Salary:Base  -2080.00 CNY
          Assets:Bank:CMB  2080.00 CNY

        2026-09-25 * "饭店" "聚餐"
          Expenses:Food  3000.00 CNY
          Assets:Bank:CMB

        2026-09-26 * "饭店" "午饭"
          Expenses:Food  90.00 CNY
          Assets:Bank:CMB

        """
        let L = ledger(t)
        var p = PayslipTemplate(employer: "星河", items: [PayslipItem(name: "基本工资", account: "Income:Salary:Base", amount: 2600),
                                                        PayslipItem(name: "餐补", account: "Income:Salary:Allowance", amount: 500),
                                                        PayslipItem(name: "请假", account: "Income:Salary:Deduction", deduct: true)],
                                account: "Assets:Bank:CMB")
        p.slug = "xinghe"
        let f = forecast(L, today: "2026-10-01", days: 40, includeDaily: true, payslips: [p], largeExpense: 2000)
        XCTAssertEqual(f.events.filter { $0.kind == .income }.map { $0.date }, ["2026-10-24"])
        XCTAssertEqual(f.events.first { $0.kind == .income }?.amount, 3100)
        // the 3000 dinner is a one-off; the 90 lunch is everyday spending
        XCTAssertEqual(f.dailySpend, 1.0, accuracy: 0.01)
        // without a template the series (two payments) is too short to count
        XCTAssertTrue(forecast(L, today: "2026-10-01", days: 40, includeDaily: false).events.filter { $0.kind == .income }.isEmpty)
    }
}
