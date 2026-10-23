import XCTest
@testable import LedgerKit

/// 年度回顾 against what Beancount works out for the same years (tools/fixtures/year_expected.py → Fixtures/money/*-years.json),
/// each currency as booked: income, expenses, months, category groups, assets and liabilities, net worth.
final class YearReviewTests: XCTestCase {
    let samples = [("realistic", "money/realistic-years.json"), ("money", "money/edge-years.json")]
    let cent = 0.005

    func expected(_ file: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL(file))) as! [String: Any]
    }
    func amounts(_ x: Any?) -> [String: Double] {
        ((x as? [String: Any]) ?? [:]).mapValues { ($0 as? NSNumber)?.doubleValue ?? 0 }
    }

    func testAgainstBeancount() throws {
        for (set, file) in samples {
            let L = loadSet(set), e = try expected(file)
            let today = e["today"] as! String
            let years = e["years"] as! [String: [String: Any]]
            XCTAssertEqual(Set(reviewYears(L)), Set(years.keys), set)
            for (y, w) in years {
                // every currency the year touches, each on its own
                var curs = Set<String>()
                for k in ["income", "expenses", "assets_change", "liabilities_change", "worth_start"] { curs.formUnion(amounts(w[k]).keys) }
                for c in curs.sorted() {
                    let r = yearReview(L, year: y, mode: .units, currency: c, today: today)
                    let tag = "\(set) \(y) \(c)"
                    XCTAssertEqual(r.through, w["through"] as? String, tag)
                    XCTAssertEqual(r.income, amounts(w["income"])[c] ?? 0, accuracy: cent, "\(tag) income")
                    XCTAssertEqual(r.expenses, amounts(w["expenses"])[c] ?? 0, accuracy: cent, "\(tag) expenses")
                    let months = (w["months"] as? [String: [String: Any]]) ?? [:]
                    for m in r.months {
                        XCTAssertEqual(m.income, amounts(months[m.month]?["income"])[c] ?? 0, accuracy: cent, "\(tag) \(m.month) income")
                        XCTAssertEqual(m.expenses, amounts(months[m.month]?["expenses"])[c] ?? 0, accuracy: cent, "\(tag) \(m.month) expenses")
                    }
                    let cats = (w["categories"] as? [String: Any]) ?? [:]
                    let want = cats.compactMapValues { amounts($0)[c] }.filter { abs($0.value) > 1e-9 }
                    XCTAssertEqual(Set(r.categories.map { $0.account }), Set(want.keys), "\(tag) category groups")
                    for g in r.categories { XCTAssertEqual(g.amount, want[g.account] ?? 0, accuracy: cent, "\(tag) \(g.account)") }
                    XCTAssertEqual(r.assetsChange, amounts(w["assets_change"])[c] ?? 0, accuracy: cent, "\(tag) assets")
                    XCTAssertEqual(r.liabilitiesChange, amounts(w["liabilities_change"])[c] ?? 0, accuracy: cent, "\(tag) liabilities")
                    XCTAssertEqual(r.worthStart ?? 0, amounts(w["worth_start"])[c] ?? 0, accuracy: cent, "\(tag) worth at the start")
                    let wm = (w["worth_by_month"] as? [String: Any]) ?? [:]
                    XCTAssertEqual(r.worthByMonth.map { $0.month }, wm.keys.sorted(), "\(tag) month ends")
                    for (m, v) in r.worthByMonth { XCTAssertEqual(v, amounts(wm[m])[c] ?? 0, accuracy: cent, "\(tag) worth \(m)") }
                }
            }
        }
    }

    func testConvertedAgreesWithItself() {
        // in one currency: the year is its months, the net its income less expenses, the categories its expenses
        let L = loadSet("realistic")
        let r = yearReview(L, year: "2025", mode: .convert("CNY"), today: TODAY)
        XCTAssertEqual(r.currency, "CNY")
        XCTAssertEqual(r.months.count, 12)
        XCTAssertEqual(r.income, r.months.reduce(0) { $0 + $1.income }, accuracy: 0.05)
        XCTAssertEqual(r.expenses, r.months.reduce(0) { $0 + $1.expenses }, accuracy: 0.05)
        XCTAssertEqual(r.expenses, r.categories.reduce(0) { $0 + $1.amount }, accuracy: 0.05)
        XCTAssertEqual(r.net, r.income - r.expenses, accuracy: 0.01)
        XCTAssertNotNil(r.savingsRate)
        XCTAssertNotNil(r.previousIncome, "2024 is there to compare with")
        XCTAssertEqual(r.biggest.count, 5)
        XCTAssertEqual(r.biggest.map { $0.amount }, r.biggest.map { $0.amount }.sorted(by: >))
        XCTAssertFalse(r.payees.isEmpty)
        XCTAssertGreaterThanOrEqual(r.dearestMonth?.expenses ?? 0, r.cheapestMonth?.expenses ?? 0)
        // the year still going on stops at today
        let now = yearReview(L, year: "2026", today: TODAY)
        XCTAssertEqual(now.through, TODAY)
        XCTAssertEqual(now.months.last?.month, String(TODAY.prefix(7)))
    }

    func testEdgeSampleByHand() {
        let L = loadSet("money")
        let r = yearReview(L, year: "2024", mode: .units, currency: "USD", today: "2024-07-31")
        // the fees are the only USD expenses: 1.00, and 10 USD less 3 HKD at 0.128 USD = 9.616, 10.616 shown to
        // the cent; the gains from selling VOO and the stock award are investment income
        XCTAssertEqual(r.expenses, 10.62, accuracy: 1e-9)
        XCTAssertEqual(r.investment.first?.account, "Income:Gains")
        XCTAssertEqual(r.investment.first?.amount ?? 0, r.income, accuracy: cent)
        let cny = yearReview(L, year: "2024", mode: .units, currency: "CNY", today: "2024-07-31")
        XCTAssertEqual(cny.biggest.first?.entry.payee, "饭店")
        XCTAssertEqual(cny.payees.first { $0.name == "饭店" }?.count, 1)
        XCTAssertNil(cny.previousIncome, "nothing the year before")
        XCTAssertTrue(reviewYears(L) == ["2024"])
        XCTAssertTrue(yearReview(L, year: "2023", today: "2024-07-31").isEmpty)
    }

    func testInvestmentAccounts() {
        XCTAssertTrue(isInvestmentIncome("Income:Invest:Dividend"))
        XCTAssertTrue(isInvestmentIncome("Income:Gains"))
        XCTAssertTrue(isInvestmentIncome("Income:Bank:Interest"))
        XCTAssertFalse(isInvestmentIncome("Income:Salary:Base"))
        XCTAssertFalse(isInvestmentIncome("Income:Rewards"))
    }
}
