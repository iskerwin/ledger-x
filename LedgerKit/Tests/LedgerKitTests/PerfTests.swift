import XCTest
@testable import LedgerKit

/// A generated ledger about ten times the size of a busy personal one (60k transactions over ten
/// years), timed through what the app does on every load and save. Each step's ceiling is about four times
/// what it took when this test was written (load 2.5 s, derived 1.3 s on the CI runner): the point is to
/// catch a change that makes something several times slower, not to benchmark the runner. The timings go to the test log (test.log in the dev release).
final class PerfTests: XCTestCase {
    static let txns = 60_000

    /// deterministic: the same ledger every run
    static func bigLedger(_ n: Int = txns) -> String {
        var out = """
        option "operating_currency" "CNY"
        2014-01-01 open Assets:Bank:Main CNY
          statement_day: 1
        2014-01-01 open Assets:Bank:HK HKD
        2014-01-01 open Assets:Cash CNY
        2014-01-01 open Liabilities:CreditCard:A CNY
          statement_day: 15
          credit_limit: 1000000
        2014-01-01 open Income:Salary CNY
        2014-01-01 open Equity:Opening

        """
        let cats = ["Expenses:Food:Dining", "Expenses:Food:Groceries", "Expenses:Transit:Taxi", "Expenses:Shopping:Household",
                    "Expenses:Digital", "Expenses:Housing:Rent", "Expenses:Travel", "Expenses:Gifts:RedPacket"]
        for c in cats { out += "2014-01-01 open \(c) CNY,HKD\n" }
        let payees = ["朴朴超市", "美团", "滴滴出行", "淘宝", "Apple", "房东", "携程", "便利店", "京东", "星巴克"]
        out += "\n2014-01-01 * \"Opening\"\n  Assets:Bank:Main  1000000.00 CNY\n  Equity:Opening\n\n"
        var seed: UInt64 = 42
        func rnd(_ m: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(m)) }
        let start = Day.date("2015-01-01")!
        let perDay = Double(n) / 3650
        for i in 0..<n {
            let date = Day.string(Calendar(identifier: .gregorian).date(byAdding: .day, value: Int(Double(i) / perDay), to: start)!)
            let cat = cats[rnd(cats.count)], payee = payees[rnd(payees.count)]
            let amount = String(format: "%.2f", Double(rnd(50000) + 100) / 100)
            switch i % 40 {
            case 0:
                out += "\(date) * \"公司\" \"工资\"\n  Income:Salary  -12000.00 CNY\n  Assets:Bank:Main\n\n"
            case 1:
                out += "\(date) * \"\(payee)\" \"港币\" #trip\n  \(cat)  \(amount) HKD\n  Assets:Bank:HK\n\n"
            case 2:
                out += "\(date) * \"\(payee)\" \"退款\" #refund ^refund-\(i)\n  \(cat)  -\(amount) CNY\n  Liabilities:CreditCard:A\n\n"
            case 3:
                out += "\(date) * \"还款\" #transfer\n  Liabilities:CreditCard:A  3000.00 CNY\n  Assets:Bank:Main\n\n"
            default:
                let fund = i % 3 == 0 ? "Assets:Cash" : i % 3 == 1 ? "Liabilities:CreditCard:A" : "Assets:Bank:Main"
                out += "\(date) * \"\(payee)\" \"消费 \(i)\"\n  \(cat)  \(amount) CNY\n  \(fund)\n\n"
            }
            if i % 4000 == 0 { out += "\(date) balance Assets:Bank:HK  0.00 HKD\n\n" }
        }
        return out
    }

    private func time<T>(_ label: String, max: Double, _ body: () throws -> T) rethrows -> T {
        let t0 = Date()
        let v = try body()
        let s = Date().timeIntervalSince(t0)
        print(String(format: "PERF %-22@ %7.2f s  (limit %.0f s)", label as NSString, s, max))
        XCTAssertLessThan(s, max, label)
        return v
    }

    func testBigLedger() throws {
        let text = Self.bigLedger()
        let L = time("load", max: 10) { loadLedger(root: "main.bean") { _ in text } }
        XCTAssertGreaterThan(L.txns.count, Self.txns)
        _ = time("derived", max: 6) { Derived(L, today: "2025-01-01") }
        // the pre-commit check loads the ledger twice and compares
        let after = time("load (after a change)", max: 10) {
            loadLedger(root: "main.bean") { _ in text + "2024-12-30 * \"X\"\n  Expenses:Travel  1.00 CNY\n  Assets:Cash\n" }
        }
        _ = time("pre-commit check", max: 3) { reviewChange(before: L, after: after) }
        _ = time("income statement", max: 2) { incomeStatement(L, from: "2024-01-01", to: "2024-12-31") }
        _ = time("balance sheet", max: 2) { balanceSheet(L, at: nil) }
        _ = time("net worth series", max: 3) { netWorthSeries(L, today: "2025-01-01") }
        _ = time("reconcile", max: 2) { reconcileDue(L, today: "2025-01-01") }
        let bill = L.txns.filter { $0.postings.contains { $0.account.hasPrefix("Assets:") && ($0.units ?? 0) < 0 } }.suffix(1000).enumerated().map { index, txn -> (row: ImportRow, funding: String?) in
            let posting = txn.postings.first { $0.account.hasPrefix("Assets:") && ($0.units ?? 0) < 0 }!
            var row = ImportRow(id: index, date: txn.date)
            row.payee = txn.payee; row.amount = abs(posting.units ?? 0)
            return (row, posting.account)
        }
        let duplicates = time("import duplicates", max: 2) { findDuplicates(bill, L) }
        XCTAssertNotNil(duplicates.first ?? nil)
        let found = duplicates.compactMap { $0?.id }
        XCTAssertEqual(Set(found).count, found.count)
        _ = try time("BQL group by", max: 3) {
            try runQuery("SELECT account, sum(position) WHERE account ~ '^Expenses' GROUP BY account ORDER BY account", L)
        }
        _ = time("CSV export", max: 4) { exportCSV(L) }
        _ = time("link check", max: 3) { linkIssues(L, subscriptions: subscriptions(L)) }
    }

    func testExportCSV() {
        let L = loadLedger(root: "main.bean") { _ in """
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Expenses:Food CNY
        2026-01-02 * "店, 家" "说 \\"好\\"" #a ^b
          Expenses:Food  12.5 CNY
          Assets:Bank
        2026-02-02 * "Later" ""
          Expenses:Food  1 CNY
          Assets:Bank
        """ }
        let csv = exportCSV(L, from: "2026-01-01", to: "2026-01-31")
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"))
        let rows = csv.dropFirst().components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(rows.count, 3)   // header + two postings; February left out
        XCTAssertTrue(rows[1].hasPrefix("2026-01-02,*,\"店, 家\",\"说 \"\"好\"\"\",Expenses:Food,12.5,CNY,a,b,"))
        XCTAssertTrue(rows[2].contains("Assets:Bank,-12.5,CNY"))
    }

    func testCachedBeforeLedgerKeepsAllSaveReviewIssues() {
        let text = Self.bigLedger(10_000)
        let cached = loadLedger { _ in text }
        let rebuilt = loadLedger { _ in text }
        let after = loadLedger { _ in text + """
        2025-01-01 * "Example" "Insufficient balance"
          Expenses:Food:Dining 99999999.00 CNY
          Assets:Bank:Main

        """ }
        let oldCount = cached.txns.count
        let freshIssues = reviewChange(before: rebuilt, after: after)
        let cachedIssues = time("cached save review", max: 3) { reviewChange(before: cached, after: after) }
        XCTAssertEqual(cachedIssues, freshIssues)
        XCTAssertTrue(cachedIssues.contains { $0.kind == .insufficient })
        XCTAssertEqual(cached.txns.count, oldCount)
    }
}

