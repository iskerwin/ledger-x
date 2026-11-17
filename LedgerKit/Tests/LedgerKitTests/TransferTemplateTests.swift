import XCTest
@testable import LedgerKit

/// 常用交易 for 转账 on the Mac's 记一笔
final class TransferTemplateTests: XCTestCase {
    private let today = "2026-06-30"

    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private func transfer(_ date: String, _ from: String, _ to: String, _ amount: String, payee: String = "") -> String {
        """
        \(date) * "\(payee)" ""
          \(to)    \(amount) CNY
          \(from)  -\(amount) CNY

        """
    }

    private let accounts = """
    2025-01-01 open Assets:Bank
    2025-01-01 open Assets:Wallet
    2025-01-01 open Liabilities:Card
    2025-01-01 open Expenses:Food

    """

    func testFrequentPairsWithTheirUsualAmount() {
        let text = accounts
            + transfer("2026-06-01", "Assets:Bank", "Liabilities:Card", "500.00")
            + transfer("2026-06-10", "Assets:Bank", "Liabilities:Card", "500.00")
            + transfer("2026-06-20", "Assets:Bank", "Liabilities:Card", "500.00", payee: "Card repay")
            + transfer("2026-06-02", "Assets:Bank", "Assets:Wallet", "100.00")
            + transfer("2026-06-12", "Assets:Bank", "Assets:Wallet", "250.00")
            + transfer("2026-06-22", "Assets:Bank", "Assets:Wallet", "80.00")
            + transfer("2026-06-03", "Assets:Wallet", "Assets:Bank", "10.00")
        let list = transferTemplates(ledger(text), today: today)
        XCTAssertEqual(list.map(\.id), ["Assets:Bank|Liabilities:Card|CNY", "Assets:Bank|Assets:Wallet|CNY"])
        XCTAssertEqual(list[0].fixed, 500)
        XCTAssertEqual(list[0].payee, "Card repay")
        XCTAssertNil(list[1].fixed)
        XCTAssertEqual(list[1].n, 3)
    }

    func testSpendingAndOldTransfersLeftOut() {
        let spend = """
        2026-06-05 * "Diner" ""
          Expenses:Food   20.00 CNY
          Assets:Bank    -20.00 CNY

        """
        let text = accounts + spend + spend + spend
            + transfer("2025-12-01", "Assets:Bank", "Assets:Wallet", "100.00")
            + transfer("2026-01-02", "Assets:Bank", "Assets:Wallet", "100.00")
            + transfer("2026-06-02", "Assets:Bank", "Assets:Wallet", "100.00")
        XCTAssertEqual(transferTemplates(ledger(text), today: today), [])
    }
}
