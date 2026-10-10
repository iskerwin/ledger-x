import XCTest
@testable import LedgerKit

/// ledger-x.json: files per kind, rules by account, and moving entries to where they belong
final class LayoutTests: XCTestCase {
    private let main = """
    option "operating_currency" "CNY"
    include "journals/2025.bean"
    2023-01-01 open Assets:Bank CNY
    2023-01-01 open Assets:Invest:Fund CNY
    2023-01-01 open Expenses:Food CNY
    2023-01-01 open Expenses:Travel:Hotel CNY
    2025-01-01 price USD 7.2 CNY

    """
    private let journal = """
    2025-01-02 * "Cafe" ""
      Expenses:Food  10 CNY
      Assets:Bank
    2025-01-03 * "Fund" ""
      Assets:Invest:Fund  100 CNY
      Assets:Bank

    """
    private func ledger() -> Ledger {
        loadLedger(root: "main.bean") { p in p == "main.bean" ? self.main : p == "journals/2025.bean" ? self.journal : "" }
    }

    private func layout() -> RepoLayout {
        var lay = RepoLayout(main: "main.bean", journal: "journals/{year}/{month}.bean")
        lay.files = [.accounts: "accounts/{root}.bean", .price: "prices.bean", .transactions: "journals/{year}/{month}.bean"]
        lay.rules = [LayoutRule(account: "Assets:Invest", file: "invest/{year}.bean")]
        return lay
    }

    func testConfigRoundTrip() {
        let c = LedgerXConfig(files: ["accounts": "accounts.bean", "price": " "], rules: [LayoutRule(account: "Assets:Invest", file: "invest.bean"), LayoutRule(account: "", file: "x")], receivable: "")
        let j = c.json()
        let back = LedgerXConfig.parse(j)
        XCTAssertEqual(back?.files, ["accounts": "accounts.bean"])
        XCTAssertEqual(back?.rules, [LayoutRule(account: "Assets:Invest", file: "invest.bean")])
        XCTAssertNil(back?.receivable)
        XCTAssertNil(LedgerXConfig.parse("not json"))
        XCTAssertEqual(LedgerXConfig.parse("{\"files\": {\"price\": \"prices.bean\"}}")?.file(.price), "prices.bean")
    }

    func testRoutingAndIncludes() {
        let L = ledger(), lay = layout()
        let text = """
        2026-03-04 * "Fund" "buy"
          Assets:Invest:Fund  50 CNY
          Assets:Bank

        2026-03-05 * "Cafe" ""
          Expenses:Food  5 CNY
          Assets:Bank

        2026-03-06 open Liabilities:Card CNY
        """
        guard case .success(let ops) = makeOps(text, L, layout: lay, pending: [], fileExists: { _ in false }, single: false) else { return XCTFail() }
        let inserts = ops.filter { $0.kind == .insert }.map { $0.path }
        XCTAssertEqual(inserts, ["invest/2026.bean", "journals/2026/03.bean", "accounts/Liabilities.bean"])
        XCTAssertEqual(Set(ops.filter { $0.kind == .include }.compactMap { $0.line }),
                       ["include \"invest/2026.bean\"", "include \"journals/2026/03.bean\"", "include \"accounts/Liabilities.bean\""])
    }

    func testMisplacedAndUsage() {
        let L = ledger(), lay = layout()
        let moves = misplacedEntries(L, layout: lay)
        let byType = Dictionary(grouping: moves) { $0.entry.type }
        XCTAssertEqual(byType[.open]?.map { $0.to }.sorted(), ["accounts/Assets.bean", "accounts/Assets.bean", "accounts/Expenses.bean", "accounts/Expenses.bean"])
        XCTAssertEqual(byType[.price]?.map { $0.to }, ["prices.bean"])
        XCTAssertEqual(byType[.txn]?.map { $0.to }.sorted(), ["invest/2025.bean", "journals/2025/01.bean"])
        let u = layoutUsage(L)
        XCTAssertEqual(u[.accounts]?.file, "main.bean")
        XCTAssertEqual(u[.accounts]?.count, 4)
        XCTAssertEqual(u[.transactions]?.file, "journals/2025.bean")
    }
}
