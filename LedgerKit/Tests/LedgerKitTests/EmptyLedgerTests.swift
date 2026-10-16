import XCTest
@testable import LedgerKit

/// a new ledger made from another's structure: the same accounts and currencies, nothing else, and it loads clean
final class EmptyLedgerTests: XCTestCase {
    func testFromRealistic() {
        let L = loadSet("realistic")
        let files = EmptyLedger.files(from: L, title: "我的账本", year: "2026")
        let N = loadLedger(root: "main.bean") { p in
            guard let t = files[p] else { throw NSError(domain: "missing", code: 0, userInfo: [NSLocalizedDescriptionKey: p]) }
            return t
        }
        XCTAssertTrue(N.errors.isEmpty, N.errors.map { $0.msg }.joined(separator: "\n"))
        XCTAssertTrue(N.txns.isEmpty)
        XCTAssertTrue(N.prices.isEmpty && N.balances.isEmpty)
        let open = Set(L.accounts.filter { $0.value.close == nil && !$0.value.implicit }.keys)
        XCTAssertEqual(Set(N.accounts.keys), open)
        XCTAssertEqual(Set(N.commodities.keys), Set(L.commodities.keys))
        XCTAssertEqual(N.base, L.base)
        XCTAssertEqual(N.options["title"]?.first ?? nil, "我的账本")
        for (a, acc) in N.accounts { XCTAssertEqual(acc.currencies, L.accounts[a]?.currencies, a) }
        // ledger-x.json reads back, with nothing of the other ledger's own
        let cfg = try! JSONSerialization.jsonObject(with: Data(files["ledger-x.json"]!.utf8)) as! [String: Any]
        XCTAssertEqual(cfg["main"] as? String, "main.bean")
        XCTAssertNil(cfg["payslips"]); XCTAssertNil(cfg["scan_cards"]); XCTAssertNil(cfg["default_funding"])
    }
}
