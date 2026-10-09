import XCTest
@testable import LedgerKit

final class CheckTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger {
        loadLedger(root: "main.bean") { _ in text }
    }

    private let base = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank:CMB CNY
    2026-01-01 open Assets:Cash CNY
      allow_negative: TRUE
    2026-01-01 open Liabilities:CreditCard:CMB CNY
      credit_limit: 1000
    2026-01-01 open Expenses:Food CNY
    2026-01-01 open Income:Salary CNY
    2026-01-01 open Equity:Opening CNY

    2026-01-02 * "Opening"
      Assets:Bank:CMB  500.00 CNY
      Equity:Opening

    2026-02-01 balance Assets:Bank:CMB 500.00 CNY

    2026-03-01 * "Salary"
      Assets:Bank:CMB  1000.00 CNY
      Income:Salary
    """

    func testCleanChangeHasNoIssues() {
        let before = ledger(base)
        let after = ledger(base + "\n2026-03-02 * \"Lunch\"\n  Expenses:Food  30.00 CNY\n  Assets:Bank:CMB\n")
        XCTAssertEqual(reviewChange(before: before, after: after), [])
    }

    func testBalanceAssertionBroken() {
        let before = ledger(base)
        let after = ledger(base + "\n2026-01-10 * \"Lunch\"\n  Expenses:Food  30.00 CNY\n  Assets:Bank:CMB\n")
        let issues = reviewChange(before: before, after: after)
        XCTAssertEqual(issues.filter { $0.kind == .balance }.count, 1)
        // the balance failure is not reported twice as a generic error
        XCTAssertEqual(issues.filter { $0.kind == .error }.count, 0)
    }

    func testExistingFailureDoesNotBlock() {
        let broken = base + "\n2026-01-10 * \"Lunch\"\n  Expenses:Food  30.00 CNY\n  Assets:Bank:CMB\n"
        let before = ledger(broken)
        let after = ledger(broken + "\n2026-03-05 * \"Dinner\"\n  Expenses:Food  20.00 CNY\n  Assets:Bank:CMB\n")
        XCTAssertEqual(reviewChange(before: before, after: after), [])
    }

    func testInsufficientBalanceAndLaterDip() {
        let before = ledger(base)
        // spending 800 on 02-15 leaves -300 before the salary arrives; the 02-01 assertion is still fine
        let after = ledger(base + "\n2026-02-15 * \"Laptop\"\n  Expenses:Food  800.00 CNY\n  Assets:Bank:CMB\n")
        let issues = reviewChange(before: before, after: after)
        let low = issues.filter { $0.kind == .insufficient }
        XCTAssertEqual(low.count, 1)
        XCTAssertEqual(low.first?.account, "Assets:Bank:CMB")
        XCTAssertTrue(low.first?.detail.contains("2026-02-15") ?? false)
    }

    func testAllowNegativeAndCreditLimit() {
        let before = ledger(base)
        let cash = ledger(base + "\n2026-03-02 * \"Taxi\"\n  Expenses:Food  50.00 CNY\n  Assets:Cash\n")
        XCTAssertEqual(reviewChange(before: before, after: cash).filter { $0.kind == .insufficient }, [])
        let card = ledger(base + "\n2026-03-02 * \"TV\"\n  Expenses:Food  1200.00 CNY\n  Liabilities:CreditCard:CMB\n")
        XCTAssertEqual(reviewChange(before: before, after: card).map { $0.kind }, [.creditLimit])
        let ok = ledger(base + "\n2026-03-02 * \"TV\"\n  Expenses:Food  900.00 CNY\n  Liabilities:CreditCard:CMB\n")
        XCTAssertEqual(reviewChange(before: before, after: ok), [])
    }

    func testOtherErrors() {
        let before = ledger(base)
        let unopened = ledger(base + "\n2026-03-02 * \"Gift\"\n  Expenses:Gifts  50.00 CNY\n  Assets:Bank:CMB\n")
        XCTAssertTrue(reviewChange(before: before, after: unopened).contains { $0.kind == .error && $0.title.contains("Expenses:Gifts") })
        let unbalanced = ledger(base + "\n2026-03-02 * \"Oops\"\n  Expenses:Food  50.00 CNY\n  Assets:Bank:CMB  -40.00 CNY\n")
        XCTAssertTrue(reviewChange(before: before, after: unbalanced).contains { $0.kind == .error })
    }

    // MARK: subscriptions

    func testPeriods() {
        XCTAssertEqual(SubPeriod.parse("monthly"), .monthly)
        XCTAssertEqual(SubPeriod.parse("half-yearly"), .halfYearly)
        XCTAssertEqual(SubPeriod.parse("45 days"), SubPeriod(45, .day))
        XCTAssertEqual(SubPeriod.parse("2 weeks"), SubPeriod(2, .week))
        XCTAssertEqual(SubPeriod(45, .day).text, "45 days")
        XCTAssertEqual(SubPeriod.monthly.add("2026-01-31", 1), "2026-02-28")
        XCTAssertEqual(SubPeriod.monthly.add("2026-01-31", 2), "2026-03-31")
        XCTAssertEqual(SubPeriod.yearly.add("2024-02-29", 1), "2025-02-28")
        XCTAssertEqual(SubPeriod.quarterly.add("2026-11-15", 1), "2027-02-15")
    }

    func testDueDatesWithExtension() {
        var s = Subscription(name: "iCloud+", amount: 21, currency: "CNY", period: .monthly, start: "2026-01-15",
                             account: "Expenses:Food", funding: "Assets:Bank:CMB")
        XCTAssertEqual(s.due(onOrAfter: "2026-01-01"), "2026-01-15")
        XCTAssertEqual(s.due(onOrAfter: "2026-10-09"), "2026-10-15")
        XCTAssertEqual(s.due(onOrAfter: "2026-10-15"), "2026-10-15")
        XCTAssertEqual(s.due(onOrBefore: "2026-10-09"), "2026-09-15")
        XCTAssertNil(s.due(onOrBefore: "2026-01-14"))
        // three free months: the next charge moves to 2027-01-20 and the monthly cycle continues from there
        s.next = "2027-01-20"
        XCTAssertEqual(s.due(onOrAfter: "2026-10-09"), "2027-01-20")
        XCTAssertEqual(s.due(onOrAfter: "2027-01-21"), "2027-02-20")
        XCTAssertNil(s.due(onOrBefore: "2026-12-31"))
        XCTAssertEqual(s.monthly, 21, accuracy: 0.001)
        XCTAssertEqual(Subscription(name: "x", amount: 120, currency: "CNY", period: .yearly, start: "2026-01-01", account: "", funding: "").monthly, 10, accuracy: 0.001)
    }

    func testSubscriptionDirectivesAndDue() {
        let sub = Subscription(name: "Music", amount: 15, currency: "CNY", period: .monthly, start: "2026-02-10",
                               account: "Expenses:Food", funding: "Assets:Bank:CMB", payee: "Apple")
        let text = subscriptionText(sub)
        XCTAssertTrue(text.hasPrefix("2026-02-10 custom \"subscription\" \"Music\" \"monthly\""))
        XCTAssertTrue(text.contains("  funding: \"Assets:Bank:CMB\""))
        let L = ledger(base + "\n" + text + "\n\n2026-03-10 * \"Apple\" \"Music\"\n  subscription: \"Music\"\n  Expenses:Food  15.00 CNY\n  Assets:Bank:CMB\n")
        XCTAssertTrue(L.errors.isEmpty, L.errors.map { $0.msg }.joined(separator: "; "))
        let subs = subscriptions(L)
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs.first?.funding, "Assets:Bank:CMB")
        XCTAssertEqual(subs.first?.payee, "Apple")
        XCTAssertEqual(subscriptionsDue(L, today: "2026-03-20").count, 0)          // paid via metadata
        XCTAssertEqual(subscriptionsDue(L, today: "2026-04-12").map { $0.date }, ["2026-04-10"])
        // paused subscriptions are never due
        var p = sub
        p.status = .paused
        XCTAssertEqual(subscriptionsDue(ledger(base + "\n" + subscriptionText(p) + "\n"), today: "2026-04-12").count, 0)
    }

    func testCandidates() {
        var t = base
        for m in 3...7 { t += "\n2026-0\(m)-05 * \"Netflix\"\n  Expenses:Food  68.00 CNY\n  Liabilities:CreditCard:CMB\n" }
        let L = ledger(t)
        let c = subscriptionCandidates(L, today: "2026-07-20")
        XCTAssertEqual(c.map { $0.payee }, ["Netflix"])
        XCTAssertEqual(c.first?.period, .monthly)
        XCTAssertEqual(c.first?.funding, "Liabilities:CreditCard:CMB")
    }
}
