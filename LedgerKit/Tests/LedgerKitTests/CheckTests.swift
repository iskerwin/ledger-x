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

    func testRunningBalanceIsUpdatedNotBlocked() {
        // 04-01 holds the balance as of now (today is 03-10): a new March entry moves it
        let text = base + "\n2026-04-01 balance Assets:Bank:CMB 1500.00 CNY ; from the bank app\n"
        let before = ledger(text)
        let after = ledger(text + "\n2026-03-05 * \"Dinner\"\n  Expenses:Food  20.00 CNY\n  Assets:Bank:CMB\n")
        XCTAssertEqual(reviewChange(before: before, after: after, today: "2026-03-10"), [])
        XCTAssertEqual(reviewChange(before: before, after: after).map { $0.kind }, [.balance])
        let run = runningBalances(before: before, after: after, today: "2026-03-10")
        XCTAssertEqual(run.count, 1)
        XCTAssertEqual(run.first?.asserted, 1500)
        XCTAssertEqual(run.first?.computed, 1480)
        // a past assertion broken by the same change is still an issue, and not a running one
        XCTAssertEqual(runningBalances(before: before, after: after, today: "2026-04-02"), [])
        // the rewritten line keeps its comment and makes the ledger pass again
        let op = runningBalanceOp(run[0], amount: 1480)
        XCTAssertTrue(op.line?.hasSuffix("1480.00 CNY ; from the bank app") ?? false)
        let fixed = insertBalance(text + "\n2026-03-05 * \"Dinner\"\n  Expenses:Food  20.00 CNY\n  Assets:Bank:CMB\n", op)
        XCTAssertEqual(reviewChange(before: before, after: ledger(fixed)), [])
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

    // MARK: audit fixes

    func testOverdraftOnAccountThatWasNegativeBefore() {
        // the bank was overdrawn once in January; a new overdraft in March must still be caught
        let old = base + "\n2026-01-03 * \"Oops\"\n  Expenses:Food  700.00 CNY\n  Assets:Bank:CMB\n2026-01-04 * \"Fix\"\n  Assets:Bank:CMB  700.00 CNY\n  Income:Salary\n"
        let before = ledger(old)
        let after = ledger(old + "\n2026-03-05 * \"TV\"\n  Expenses:Food  1600.00 CNY\n  Assets:Bank:CMB\n")
        let low = reviewChange(before: before, after: after).filter { $0.kind == .insufficient }
        XCTAssertEqual(low.count, 1)
        XCTAssertTrue(low.first?.detail.contains("2026-03-05") ?? false)
        // an unrelated change leaves the old January dip alone
        let other = ledger(old + "\n2026-03-05 * \"Lunch\"\n  Expenses:Food  10.00 CNY\n  Assets:Bank:CMB\n")
        XCTAssertEqual(reviewChange(before: before, after: other), [])
    }

    func testOldErrorWithChangedNumbersIsNotNew() {
        // the same unbalanced transaction, off by a different amount after an unrelated edit, is not new
        let a = base + "\n2026-03-02 * \"Odd\"\n  Expenses:Food  50.00 CNY\n  Assets:Bank:CMB  -40.00 CNY\n"
        let b = base + "\n2026-03-02 * \"Odd\"\n  Expenses:Food  50.00 CNY\n  Assets:Bank:CMB  -45.00 CNY\n"
        XCTAssertEqual(reviewChange(before: ledger(a), after: ledger(b)).filter { $0.kind == .error }, [])
    }

    func testShortPeriodsAndTaggedPayments() {
        var weekly = Subscription(name: "Gym", amount: 30, currency: "CNY", period: .weekly, start: "2026-03-03",
                                  account: "Expenses:Food", funding: "Assets:Bank:CMB")
        // paid on 03-10 for that week; the 03-17 charge is not covered by it
        let L = ledger(base + "\n2026-03-10 * \"Gym\"\n  Expenses:Food  30.00 CNY\n  Assets:Bank:CMB\n")
        XCTAssertTrue(subscriptionPaid(weekly, due: "2026-03-10", L))
        XCTAssertFalse(subscriptionPaid(weekly, due: "2026-03-17", L))
        // a payment tagged for another subscription doesn't count, even with a similar amount
        weekly.amount = 28
        let tagged = ledger(base + "\n2026-03-10 * \"X\"\n  subscription: \"Other\"\n  Expenses:Food  30.00 CNY\n  Assets:Bank:CMB\n")
        XCTAssertFalse(subscriptionPaid(weekly, due: "2026-03-10", tagged))
    }

    func testMalformedNextAndQuoting() {
        let text = "2026-01-15 custom \"subscription\" \"A\\\\B \\\"x\\\"\" \"monthly\" 10.00 CNY\n  next: \"2026-06\"\n"
        let L = ledger(base + "\n" + text)
        let s = subscriptions(L)
        XCTAssertEqual(s.count, 1)
        XCTAssertNil(s.first?.next)
        XCTAssertEqual(s.first?.due(onOrAfter: "2026-10-10"), "2026-10-15")   // returns instead of looping
        // names with quotes and backslashes survive a round trip
        let back = ledger(base + "\n" + subscriptionText(s[0]) + "\n")
        XCTAssertEqual(subscriptions(back).first?.name, s[0].name)
    }

    func testLargeForeignCurrencyExpenseBalances() {
        let L = loadSet("realistic")
        let D = Derived(L)
        var d = Draft()
        d.kind = .expense
        d.date = TODAY
        d.payee = "Apple"
        d.amount = "9999.99"
        d.currency = "CNY"
        d.account = "Expenses:Shopping:Household"
        d.funding = "Assets:Bank:BOCHK"
        d.paid = "10987.65"
        let text = draftText(d, L, D)
        XCTAssertTrue(text.contains("@@ 10987.65 HKD"), text)
        XCTAssertTrue(checkText(text, L).ok, text)
    }

    func testImportDuplicatesMatchOnce() {
        var t = base
        t += "\n2026-03-02 * \"Cafe\"\n  Expenses:Food  15.00 CNY\n  Assets:Bank:CMB\n"
        let L = ledger(t)
        var a = ImportRow(id: 0, date: "2026-03-02"); a.amount = 15; a.payee = "Cafe"
        var b = ImportRow(id: 1, date: "2026-03-02"); b.amount = 15; b.payee = "Cafe"
        let d = findDuplicates([(row: a, funding: "Assets:Bank:CMB"), (row: b, funding: "Assets:Bank:CMB")], L)
        XCTAssertEqual(d.compactMap { $0 }.count, 1)          // the second coffee is a new purchase
        var refund = a; refund.direction = .income
        XCTAssertNil(findDuplicate(refund, funding: "Assets:Bank:CMB", L))
    }

    func testLinkWholeWord() {
        let text = "2026-03-02 * \"Trip\" \"x\" ^trip-2026\n  Expenses:Food  1.00 CNY\n  Assets:Cash\n"
        var op = Op(kind: .link, path: "x.bean")
        op.header = "2026-03-02 * \"Trip\" \"x\" ^trip-2026"
        op.headerLine = 1
        op.link = "trip"
        op.add = " ^trip"
        XCTAssertTrue(addLinkToHeader(text, op)?.hasPrefix("2026-03-02 * \"Trip\" \"x\" ^trip-2026 ^trip") ?? false)
    }
}
