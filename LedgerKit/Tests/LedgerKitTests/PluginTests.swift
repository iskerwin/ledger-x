import XCTest
@testable import LedgerKit

/// The plugins the app runs (check_commodity, implicit_prices, noduplicates, leafonly) against what Beancount
/// reports for the same ledger (tools/plugins_expected.py → Fixtures/plugins/expected.json).
final class PluginTests: XCTestCase {
    lazy var L = loadSet("plugins")
    lazy var want = loadJSON("plugins/expected.json")

    func tagged(_ name: String) -> [LedgerError] { L.errors.filter { $0.msg.contains("(\(name))") || $0.msg.contains("（\(name)）") } }

    func testCheckCommodity() {
        let errs = tagged("check_commodity")
        let got = errs.compactMap { e -> String? in if case .declareCommodity(let c)? = e.fix { return c } else { return nil } }
        XCTAssertEqual(got, want["missing_commodities"] as? [String])
        XCTAssertEqual(errs.count, got.count, "each one can be put right")
        XCTAssertTrue(errs.allSatisfy { $0.entry != nil }, "points at where the currency is used")
    }

    func testLeafOnly() {
        let accounts = want["leafonly"] as! [String]
        let errs = tagged("leafonly")
        XCTAssertEqual(errs.count, accounts.count)
        for a in accounts { XCTAssertTrue(errs.contains { $0.msg.hasPrefix(a + " ") }, a) }
        // the error is on the account's open directive
        XCTAssertTrue(errs.allSatisfy { $0.entry?.type == .open })
    }

    func testNoDuplicates() {
        let pairs = (want["duplicates"] as! [[String]]).map { $0[0] + " = " + $0[1] }
        let got = tagged("noduplicates").map { e -> String in
            let other = e.msg.range(of: #"[\w./-]+\.bean:\d+"#, options: .regularExpression).map { String(e.msg[$0]) } ?? "?"
            return "\(e.file ?? ""):\(e.line ?? 0) = \(other)"
        }
        XCTAssertEqual(got.sorted(), pairs.sorted())
    }

    func testImplicitPrices() {
        func key(_ d: String, _ c: String, _ n: Double, _ q: String, _ made: Bool) -> String { "\(d) \(c) \(String(format: "%.6f", n)) \(q) \(made)" }
        let expected = (want["prices"] as! [[Any]]).map { key($0[0] as! String, $0[1] as! String, ($0[2] as! NSNumber).doubleValue, $0[3] as! String, $0[4] as! Bool) }
        let got = L.prices.map { key($0.date, $0.currency ?? "", $0.number, $0.quote ?? "", $0.synthetic) }
        XCTAssertEqual(got.sorted(), expected.sorted())
        for (pair, v) in want["latest"] as! [String: [Any]] {
            let p = pair.components(separatedBy: "/")
            let px = latestPrice(L, p[0], p[1])
            XCTAssertEqual(px?.date, v[0] as? String, pair)
            XCTAssertEqual(px?.number ?? 0, (v[1] as! NSNumber).doubleValue, accuracy: 1e-9, pair)
        }
        // the made prices don't change the rates (the postings were already counted)
        XCTAssertEqual(toCNY(L, 1, "USD", "2024-01-05") ?? 0, 7.10, accuracy: 1e-9)
        XCTAssertEqual(toCNY(L, 1, "USD", "2024-01-06") ?? 0, 7.15, accuracy: 1e-9)
    }

    func testNothingElseAndTheRestNamed() {
        // every error is one of the plugins' (Beancount reports nothing else for this ledger)
        let mine = ["check_commodity", "leafonly", "noduplicates"].reduce(0) { $0 + tagged($1).count }
        XCTAssertEqual(L.errors.filter { !$0.soft }.count, mine, L.errors.map { $0.msg }.joined(separator: "\n"))
        XCTAssertEqual(unexecutedPlugins(L), ["beancount.plugins.check_closing"])
    }

    func testOnlyWhenDeclared() {
        // the same entries without the plugin lines: none of it
        let dir = fixtureURL("plugins")
        let bare = loadLedger(root: "main.bean") { path in
            let text = try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
            return text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("plugin ") }.joined(separator: "\n")
        }
        XCTAssertTrue(bare.errors.filter { !$0.soft }.isEmpty, bare.errors.map { $0.msg }.joined(separator: "\n"))
        XCTAssertFalse(bare.prices.contains { $0.synthetic })
        XCTAssertTrue(unexecutedPlugins(bare).isEmpty)
    }
}
