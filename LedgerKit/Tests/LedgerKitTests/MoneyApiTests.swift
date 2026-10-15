import XCTest
@testable import LedgerKit

/// The functions the money on screen comes from, against figures Beancount itself worked out
/// (tools/money_expected.py → Fixtures/money/*.json): balances on given days, holdings and their lots,
/// the latest price of each pair, and the totals of every account and parent in the account tree.
final class MoneyApiTests: XCTestCase {
    /// sample folder, expected-values file
    let samples = [("realistic", "money/realistic.json"), ("money", "money/edge.json")]
    let cent = 0.005

    func expected(_ file: String) throws -> [String: Any] {
        let d = try Data(contentsOf: fixtureURL(file))
        return try JSONSerialization.jsonObject(with: d) as! [String: Any]
    }

    /// every non-zero amount on both sides agrees to the cent
    func assertSame(_ got: [String: [String: Double]], _ want: [String: [String: Double]], _ what: String,
                    file: StaticString = #filePath, line: UInt = #line) {
        let keys = Set(got.keys).union(want.keys)
        for a in keys.sorted() {
            let g = (got[a] ?? [:]).filter { abs($0.value) > 1e-9 }, w = want[a] ?? [:]
            for c in Set(g.keys).union(w.keys).sorted() {
                XCTAssertEqual(g[c] ?? 0, w[c] ?? 0, accuracy: cent, "\(what) \(a) \(c)", file: file, line: line)
            }
        }
    }

    func amounts(_ x: Any?) -> [String: [String: Double]] {
        ((x as? [String: [String: Any]]) ?? [:]).mapValues { $0.mapValues { ($0 as? NSNumber)?.doubleValue ?? 0 } }
    }

    func testBalancesAt() throws {
        for (set, file) in samples {
            let L = loadSet(set), e = try expected(file)
            for d in e["dates"] as! [String] {
                let want = amounts((e["balances"] as! [String: Any])[d])
                XCTAssertFalse(want.isEmpty, "\(set) \(d)")
                assertSame(balancesAt(L, d), want, "\(set) \(d)")
            }
        }
    }

    func testHoldingsAndLots() throws {
        for (set, file) in samples {
            let L = loadSet(set), e = try expected(file)
            let want = e["holdings"] as! [[String: Any]]
            let got = holdings(L)
            XCTAssertEqual(got.count, want.count, set)
            for w in want {
                let acct = w["account"] as! String, c = w["currency"] as! String, q = w["cost_currency"] as! String
                guard let h = got.first(where: { $0.acct == acct && $0.c == c && $0.q == q }) else {
                    XCTFail("\(set): no holding \(acct) \(c) at cost in \(q)"); continue
                }
                XCTAssertEqual(h.units, (w["units"] as! NSNumber).doubleValue, accuracy: 1e-9, "\(set) \(c) units")
                XCTAssertEqual(h.cost, (w["cost"] as! NSNumber).doubleValue, accuracy: cent, "\(set) \(c) cost")
                let wl = w["lots"] as! [[String: Any]]
                let gl = h.lots.sorted { (($0.cost?.date ?? ""), $0.cost?.number ?? 0) < (($1.cost?.date ?? ""), $1.cost?.number ?? 0) }
                XCTAssertEqual(gl.count, wl.count, "\(set) \(c) lots")
                for (g, x) in zip(gl, wl) {
                    XCTAssertEqual(g.units, (x["units"] as! NSNumber).doubleValue, accuracy: 1e-9, "\(set) \(c) lot units")
                    XCTAssertEqual(g.cost?.number ?? 0, (x["cost"] as! NSNumber).doubleValue, accuracy: 1e-9, "\(set) \(c) lot cost")
                    XCTAssertEqual(g.cost?.date, x["date"] as? String, "\(set) \(c) lot date")
                }
                // market value and gain follow from the latest price
                if let px = latestPrice(L, c, q) {
                    XCTAssertEqual(h.value ?? 0, h.units * px.number, accuracy: cent)
                    XCTAssertEqual(h.pnl ?? 0, h.units * px.number - h.cost, accuracy: cent)
                }
            }
        }
    }

    func testLatestPrice() throws {
        for (set, file) in samples {
            let L = loadSet(set), e = try expected(file)
            for (pair, v) in e["prices"] as! [String: [String: Any]] {
                let p = pair.components(separatedBy: "/")
                let got = latestPrice(L, p[0], p[1])
                XCTAssertEqual(got?.date, v["date"] as? String, "\(set) \(pair)")
                XCTAssertEqual(got?.number ?? 0, (v["number"] as! NSNumber).doubleValue, accuracy: 1e-9, "\(set) \(pair)")
            }
            XCTAssertNil(latestPrice(L, "XYZ", "CNY"))
        }
    }

    func testAccountTreeTotals() throws {
        for (set, file) in samples {
            let L = loadSet(set), e = try expected(file)
            let last = (e["dates"] as! [String]).last!
            var inv: [String: Inventory] = [:]
            for (a, cs) in balancesAt(L, last) { for (c, n) in cs { inv[a, default: Inventory()].add(n, c) } }
            let want = amounts(e["tree"])
            var got: [String: [String: Double]] = [:]
            func walk(_ n: AccountNode) {
                got[n.name] = Dictionary(uniqueKeysWithValues: n.balance.nonZero.map { ($0.0, $0.1) })
                for ch in n.children { walk(ch) }
            }
            for root in ["Assets", "Liabilities", "Equity", "Income", "Expenses"] where want[root] != nil {
                walk(accountTree(inv, root: root, L, at: last))
            }
            assertSame(got.filter { !$0.value.isEmpty }, want, "\(set) tree")
        }
    }

    /// the edge sample, spelled out: FIFO across lots, a total-cost lot, a pad, prices on the same day
    func testEdgeCasesByHand() throws {
        let L = loadSet("money")
        let june = balancesAt(L, "2024-06-30")
        XCTAssertEqual(june["Assets:Wallet"]?["CNY"] ?? 0, 321.45, accuracy: 1e-9, "the pad fills the wallet to the asserted balance")
        XCTAssertEqual(balancesAt(L, "2024-07-31")["Assets:Wallet"]?["CNY"] ?? 0, 311.45, accuracy: 1e-9, "a later entry counts only after its day")
        let voo = holdings(L).first { $0.c == "VOO" }
        XCTAssertEqual(voo?.units ?? 0, 4.5, accuracy: 1e-9, "3 + 2 + 4.5 bought, 4 then 1 sold")
        XCTAssertEqual(voo?.lots.first?.cost?.number ?? 0, 445.20, accuracy: 1e-9, "{{2003.40 USD}} for 4.5 is 445.20 each")
        XCTAssertEqual(latestPrice(L, "USD", "CNY")?.number ?? 0, 7.26, accuracy: 1e-9, "the later of two prices on one day")
        XCTAssertEqual(holdings(L).first { $0.c == "TSLA" }?.lots.first?.cost?.date, "2024-05-01", "a lot date given in the cost")
    }
}
