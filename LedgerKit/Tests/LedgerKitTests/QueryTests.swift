import XCTest
@testable import LedgerKit

final class QueryTests: XCTestCase {
    lazy var L = loadSet("realistic")
    lazy var D = Derived(L, today: TODAY)

    func q(_ s: String) throws -> QueryResult { try runQuery(s, L) }

    func testBalancesMatchLedger() throws {
        let r = try q("SELECT account, SUM(position) AS balance WHERE account ~ \"^Assets:\" GROUP BY account ORDER BY account")
        XCTAssertEqual(r.columns, ["account", "balance"])
        for row in r.rows {
            guard case .string(let a) = row[0], case .inventory(let inv) = row[1] else { return XCTFail("types \(row)") }
            for (c, n) in L.final[a] ?? [:] where abs(n) > 1e-6 {
                XCTAssertEqual(inv.amounts[c] ?? 0, n, accuracy: 1e-6, "\(a) \(c)")
            }
        }
        XCTAssertEqual(r.rows.map { $0[0].text }, r.rows.map { $0[0].text }.sorted())
        let b = try q("BALANCES WHERE account ~ '^Liabilities'")
        XCTAssertEqual(b.rows.count, 1)
    }

    func testMonthlyExpensesMatchOverview() throws {
        let r = try q("SELECT year, month, SUM(CONVERT(position, 'CNY')) AS total WHERE account ~ '^Expenses:' GROUP BY year, month ORDER BY year, month")
        XCTAssertFalse(r.rows.isEmpty)
        for row in r.rows {
            let key = String(format: "%04d-%02d", Int(row[0].sortNumber!), Int(row[1].sortNumber!))
            XCTAssertEqual(row[2].sortNumber ?? 0, D.monthExp[key] ?? 0, accuracy: 0.01, key)
        }
        // newest first, and LIMIT
        let d = try q("SELECT year, month, SUM(position) GROUP BY 1, 2 ORDER BY year DESC, month DESC LIMIT 3")
        XCTAssertEqual(d.rows.count, 3)
        XCTAssertEqual(d.rows[0][1].sortNumber, 10)
    }

    func testUserQueriesRun() throws {
        let file = """
        -- 所有资产账户余额

        SELECT account, SUM(position) AS balance
        WHERE account ~ "^Assets:"
        GROUP BY account
        ORDER BY account

        -- 按一级分类汇总（当年）

        SELECT PARENT(account) AS category, SUM(position) AS total
        WHERE account ~ "^Expenses:" AND year = 2026
        GROUP BY category
        ORDER BY total DESC

        -- 单月最大支出 Top 20

        SELECT date, payee, narration, position
        WHERE account ~ "^Expenses:" AND year = 2026 AND month = 6
        ORDER BY position DESC
        LIMIT 20
        """
        let qs = parseBQLFile(file, file: "queries/x.bql")
        XCTAssertEqual(qs.map { $0.name }, ["所有资产账户余额", "按一级分类汇总（当年）", "单月最大支出 Top 20"])
        for s in qs { XCTAssertNoThrow(try q(s.text), s.name) }
        let top = try q(qs[2].text)
        XCTAssertLessThanOrEqual(top.rows.count, 20)
        let nums = top.rows.compactMap { $0[3].sortNumber }
        XCTAssertEqual(nums, nums.sorted(by: >))
        let cat = try q(qs[1].text)
        XCTAssertTrue(cat.rows.allSatisfy { $0[0].text.hasPrefix("Expenses:") })
    }

    func testBuiltinsAndFeatures() throws {
        for s in builtinQueries { XCTAssertNoThrow(try q(s.text), s.name) }
        let c = try q("SELECT COUNT(*) WHERE account = 'Expenses:Subscription:Phone'")
        XCTAssertEqual(c.rows.first?.first?.sortNumber, Double(L.txns.filter { $0.payee == "UniCom" }.count))
        let dist = try q("SELECT DISTINCT payee WHERE account ~ 'Expenses' ORDER BY payee")
        XCTAssertEqual(Set(dist.rows.map { $0[0].text }).count, dist.rows.count)
        let tags = try q("SELECT date, narration WHERE 'transfer' IN tags")
        XCTAssertTrue(tags.rows.count > 0)
        let j = try q("JOURNAL 'Assets:Bank:CGB'")
        XCTAssertEqual(j.columns.last, "balance")
        let from = try q("SELECT COUNT(*) FROM year = 2025 WHERE account ~ 'Expenses'")
        XCTAssertTrue((from.rows.first?.first?.sortNumber ?? 0) > 0)
        XCTAssertThrowsError(try q("SELECT nope"))
        XCTAssertThrowsError(try q("SELECT account WHERE"))
        let arith = try q("SELECT 1 + 2 * 3 AS x, ROOT('Expenses:Food:Drinks', 2) AS r, LEAF('A:B:C') AS l LIMIT 1")
        XCTAssertEqual(arith.rows.first?.map { $0.text }, ["7", "Expenses:Food", "C"])
    }

    func testStatements() {
        let inc = incomeStatement(L, from: "2026-01-01", to: "2026-12-31")
        let year = D.monthExp.filter { $0.key.hasPrefix("2026") }.values.reduce(0, +)
        XCTAssertEqual(inc.expenses.total, year, accuracy: 0.01)
        let bs = balanceSheet(L, at: nil)
        var nw = 0.0
        for (a, cs) in L.final where a.hasPrefix("Assets") || a.hasPrefix("Liabilities") { for (c, n) in cs { nw += toCNY(L, n, c) ?? 0 } }
        XCTAssertEqual(bs.netWorth, nw, accuracy: 0.01)
        XCTAssertFalse(netWorthSeries(L, today: TODAY).isEmpty)
    }

    func testRemoveBalanceLine() throws {
        let text = "2026-01-01 balance Assets:Cash        10.00 CNY\n2026-02-01 balance Assets:Cash        20.00 CNY\n\n2026-02-01 balance Assets:Bank        5.00 CNY\n"
        var op = Op(kind: .remove, path: "b.bean")
        op.line = "2026-02-01 balance Assets:Cash        20.00 CNY"
        let out = try applyOps(text, path: "b.bean", ops: [op], strict: true)
        XCTAssertEqual(out, "2026-01-01 balance Assets:Cash        10.00 CNY\n\n2026-02-01 balance Assets:Bank        5.00 CNY\n")
        op.line = "2026-03-01 balance Assets:Cash 1 CNY"
        XCTAssertThrowsError(try applyOps(text, path: "b.bean", ops: [op], strict: true))
    }

    func testRenameAndReplace() throws {
        let text = """
        2025-01-01 open Expenses:Food:Drinks CNY
        2025-01-01 open Expenses:Food:DrinksExtra CNY

        2025-02-01 * "瑞幸" "拿铁"
          Expenses:Food:Drinks:Coffee          9.90 CNY
          Expenses:Food:Drinks                 1.00 CNY
          Assets:Cash
        """
        XCTAssertEqual(countAccount(text, "Expenses:Food:Drinks"), 3)
        var op = Op(kind: .rename, path: "a.bean")
        op.old = "Expenses:Food:Drinks"
        op.text = "Expenses:Food:Coffee"
        let out = try applyOps(text, path: "a.bean", ops: [op], strict: true)
        XCTAssertTrue(out.contains("open Expenses:Food:Coffee CNY"))
        XCTAssertTrue(out.contains("Expenses:Food:Coffee:Coffee"))
        XCTAssertTrue(out.contains("Expenses:Food:DrinksExtra"))
        XCTAssertEqual(countAccount(out, "Expenses:Food:Drinks"), 0)

        var rp = Op(kind: .replace, path: "a.bean")
        rp.old = "2025-01-01 open Expenses:Food:DrinksExtra CNY"
        rp.text = "2025-01-01 open Expenses:Food:DrinksExtra CNY,USD\n  name: \"饮料\""
        let out2 = try applyOps(text, path: "a.bean", ops: [rp], strict: true)
        XCTAssertTrue(out2.contains("DrinksExtra CNY,USD\n  name: \"饮料\"\n\n2025-02-01"))
        rp.old = "nope"
        XCTAssertThrowsError(try applyOps(text, path: "a.bean", ops: [rp], strict: true))
    }

    func testBQLFileRoundTrip() {
        let qs = [SavedQuery(name: "咖啡", text: "SELECT payee\nWHERE account = \"Expenses:Food:Drinks\"", source: "ledger"),
                  SavedQuery(name: "旅行", text: "SELECT date\nORDER BY date", source: "ledger")]
        let back = parseBQLFile(serializeBQL(qs), file: "queries/custom.bql")
        XCTAssertEqual(back.map { $0.name }, ["咖啡", "旅行"])
        XCTAssertEqual(back.map { $0.text }, qs.map { $0.text })
        XCTAssertEqual(back[1].id, "file:queries/custom.bql#1")
        XCTAssertEqual(bqlLocation(back[1].id)?.path, "queries/custom.bql")
        XCTAssertEqual(bqlLocation(back[1].id)?.index, 1)
        XCTAssertNil(bqlLocation("b:monthly"))
    }
}
