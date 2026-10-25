import XCTest
@testable import LedgerKit

/// The accounts page reads year pace, this year's categories, checks due and the attachment count from the
/// single pass that builds Derived, and the net-worth series from the ledger's memo. Both have to match the
/// functions the page used to call, including another currency, an account left out, and the day the numbers stop.
final class AccountsPassTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger {
        let L = loadLedger(root: "main.bean") { _ in text }
        XCTAssertTrue(L.errors.isEmpty, L.errors.map(\.msg).joined(separator: "\n"))
        return L
    }

    private let text = """
    option "operating_currency" "CNY"
    2024-01-01 open Assets:Bank CNY
    2024-01-01 open Assets:Cash USD
    2024-01-01 open Assets:Wallet CNY
    2024-01-01 open Liabilities:CreditCard:CMB CNY,USD
      statement_day: 10
    2024-01-01 open Equity:Opening
    2024-01-01 open Income:Salary
    2024-01-01 open Expenses:Food
    2024-01-01 open Expenses:Travel

    2024-01-02 * "期初"
      Assets:Bank  10000.00 CNY
      Equity:Opening

    2024-06-01 * "午饭"
      Expenses:Food  400.00 CNY
      Assets:Bank

    2025-02-10 * "晚饭"
      Expenses:Food  100.00 CNY
      Assets:Bank

    2025-03-01 * "跨月"
      Expenses:Food  9.00 CNY
      Assets:Bank

    2025-02-01 price USD 7.00 CNY

    2026-01-05 * "工资"
      Assets:Bank  6000.00 CNY
      Income:Salary

    ; 3 月 10 日之前卡上就有人民币。两个币种都接近 0、又没对过时，待核对会略过这个币种。
    2026-01-20 * "开卡"
      Equity:Opening  20.00 CNY
      Liabilities:CreditCard:CMB

    ; 换汇写上 @，两笔才平衡。现金仍是 100 美元，净资产按 price 折算，不按这笔的 @。
    2026-02-01 * "换汇"
      Assets:Cash  100.00 USD @ 7.00 CNY
      Assets:Bank  -700.00 CNY

    2026-02-10 * "午饭"
      Expenses:Food  30.00 CNY
      Assets:Bank

    2026-02-10 * "机票"
      Expenses:Travel  20.00 USD
      Assets:Cash

    2026-03-01 * "零钱"
      Assets:Wallet  100.00 CNY
      Assets:Bank

    2026-03-10 * "账单日"
      Expenses:Food  10.00 CNY
      Liabilities:CreditCard:CMB

    2026-03-15 * "今天"
      Expenses:Food  8.00 CNY
      Assets:Bank

    2026-03-16 * "明天"
      Expenses:Food  100.00 CNY
      Assets:Bank

    2026-03-20 price USD 8.00 CNY

    2026-03-12 * "外币账单" ^doc-bill
      Expenses:Travel  4.00 USD
      Liabilities:CreditCard:CMB

    2026-03-12 document Liabilities:CreditCard:CMB "documents/receipts/bill.jpg" ^doc-bill
    2026-03-20 document Assets:Bank "documents/bank/statement.pdf"

    """

    private func ytdMap(_ rows: [(account: String, amount: Double)]) -> [String: Double] {
        Dictionary(rows.map { ($0.account, $0.amount) }, uniquingKeysWith: +)
    }

    func testYearPaceAndCategoriesMatchIncludingTheDayTheyStop() {
        let L = ledger(text)
        let today = "2026-03-15"
        let d = Derived(L, today: today)
        let pace = yearPace(L, year: "2026", today: today)
        XCTAssertEqual(d.yearPace, pace)
        XCTAssertEqual(ytdMap(d.ytdCategories), ytdMap(ytdCategories(L, year: "2026")))
        // 3 月 16 日的 100 还没到：月均不含它。今年的分类表按整年，含它。
        let tomorrow = Derived(L, today: "2026-03-16")
        XCTAssertEqual(tomorrow.yearPace, yearPace(L, year: "2026", today: "2026-03-16"))
        XCTAssertGreaterThan(tomorrow.yearPace.monthlySpent, d.yearPace.monthlySpent)
        XCTAssertEqual(ytdMap(d.ytdCategories), ytdMap(tomorrow.ytdCategories))
        XCTAssertEqual(ytdMap(d.ytdCategories)["Expenses:Food"] ?? 0, 30 + 10 + 8 + 100, accuracy: 1e-6)
        // 20 USD 的机票按 2 月的 7 折成人民币，不按 3 月 20 日的 8
        XCTAssertEqual(ytdMap(d.ytdCategories)["Expenses:Travel"] ?? 0, 20 * 7 + 4 * 7, accuracy: 1e-6)
        // 去年同期只到 3 月 15 日，不含 2025 年更晚的账；2024 年已经早于去年 2 月，所以有比较
        XCTAssertNotNil(d.yearPace.spentChange)
        XCTAssertEqual(d.yearPace.monthlySaved, pace.monthlySaved, accuracy: 1e-9)
    }

    func testALeapDayStopsLastYearOnThe28th() {
        let leap = text
            .replacingOccurrences(of: "2024-", with: "Y4-")
            .replacingOccurrences(of: "2025-", with: "Y5-")
            .replacingOccurrences(of: "2026-", with: "Y6-")
            .replacingOccurrences(of: "Y4-", with: "2026-")
            .replacingOccurrences(of: "Y5-", with: "2027-")
            .replacingOccurrences(of: "Y6-", with: "2028-")
        let L = ledger(leap)
        let d = Derived(L, today: "2028-02-29")
        XCTAssertEqual(d.yearPace, yearPace(L, year: "2028", today: "2028-02-29"))
        // 去年没有 2 月 29 日：比较停在 28 日，3 月的账不进去
        let later = yearPace(L, year: "2028", today: "2028-03-01").spentChange
        XCTAssertNotEqual(d.yearPace.spentChange, later)
    }

    func testChecksDueMatchOnAndAfterTheStatementDay() {
        let L = ledger(text)
        for today in ["2026-03-09", "2026-03-10", "2026-03-15"] {
            let d = Derived(L, today: today)
            XCTAssertEqual(d.reconcileDue, reconcileDue(L, today: today), today)
        }
        let before = Derived(L, today: "2026-03-09").reconcileDue.first { $0.account == "Liabilities:CreditCard:CMB" && $0.currency == "CNY" }
        let on = Derived(L, today: "2026-03-10").reconcileDue.first { $0.account == "Liabilities:CreditCard:CMB" && $0.currency == "CNY" }
        // 9 日对的是 2 月 10 日那期，3 月 10 日的账单还没到；10 日当天的一笔算进「此后」
        XCTAssertEqual(before?.day, "2026-02-10")
        XCTAssertEqual(before?.since, 0)
        XCTAssertEqual(on?.day, "2026-03-10")
        XCTAssertEqual(on?.since, 1)
        XCTAssertNotNil(Derived(L, today: "2026-03-15").reconcileDue.first { $0.account == "Liabilities:CreditCard:CMB" && $0.currency == "USD" })
    }

    func testAttachmentCountMatchesTheLinkedDocuments() {
        let L = ledger(text)
        let d = Derived(L, today: "2026-03-15")
        XCTAssertEqual(d.attachmentCount, transactionAttachments(L).count)
        XCTAssertEqual(d.attachmentCount, 1)
    }

    func testNetWorthIsMemoisedAndLeavesOutAccountsAndFuturePrices() {
        let L = ledger(text)
        let today = "2026-03-15"
        let exclude = ["Assets:Wallet"]
        let series = netWorthSeries(L, today: today, exclude: exclude)
        let again = netWorthSeries(L, today: today, exclude: exclude)
        let walk = netWorthSeriesWalk(L, today: today, exclude: exclude)
        XCTAssertEqual(series.map(\.month), again.map(\.month))
        XCTAssertEqual(series.map(\.netWorth), walk.map(\.netWorth))
        XCTAssertEqual(series.map(\.assets), walk.map(\.assets))
        XCTAssertEqual(series.map(\.liabilities), walk.map(\.liabilities))
        XCTAssertEqual(netWorthSinceLastMonth(L, today: today, exclude: exclude),
                       series[series.count - 1].netWorth - series[series.count - 2].netWorth)
        // 3 月 15 日现金里的 80 美元仍按 7 折算；3 月 31 日才用 20 日公布的 8。不计入现金时两边都少掉这一截。
        let mid = netWorthSeries(L, today: today).last!.netWorth
        let end = netWorthSeries(L, today: "2026-03-31").last!.netWorth
        let midCash = netWorthSeries(L, today: today, exclude: ["Assets:Cash"]).last!.netWorth
        let endCash = netWorthSeries(L, today: "2026-03-31", exclude: ["Assets:Cash"]).last!.netWorth
        XCTAssertEqual(mid - midCash, 80 * 7, accuracy: 1e-6)
        XCTAssertEqual(end - endCash, 80 * 8, accuracy: 1e-6)
        // 3 月 1 日拨进钱包的 100：不计入钱包时，较上月末少这 100，月末净资产也少这 100
        let allChange = netWorthSinceLastMonth(L, today: today)!
        let leftChange = netWorthSinceLastMonth(L, today: today, exclude: exclude)!
        XCTAssertEqual(allChange - leftChange, 100, accuracy: 1e-6)
        XCTAssertEqual(mid - netWorthSeries(L, today: today, exclude: exclude).last!.netWorth, 100, accuracy: 1e-6)
    }
}
