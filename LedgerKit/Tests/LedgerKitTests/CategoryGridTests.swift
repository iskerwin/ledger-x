import XCTest
@testable import LedgerKit

/// 记一笔的分类宫格: groups, their order, the last used account in each, default icons
final class CategoryGridTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    func testGroups() {
        let L = ledger("""
        option "operating_currency" "CNY"
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Assets:Receivable:Reimbursement
        2026-01-01 open Expenses:Food:Dining
        2026-01-01 open Expenses:Food:Drinks
        2026-01-01 open Expenses:Transit:Taxi
        2026-01-01 open Expenses:Travel
        2026-01-01 open Expenses:Old
        2026-02-01 close Expenses:Old
        2026-01-01 open Income:Salary:Base

        2026-09-01 * "咖啡店" "拿铁"
          Expenses:Food:Drinks  30.00 CNY
          Assets:Bank
        2026-09-02 * "饭店" "午饭"
          Expenses:Food:Dining  50.00 CNY
          Assets:Bank
        2026-09-03 * "饭店" "晚饭"
          Expenses:Food:Dining  60.00 CNY
          Assets:Bank
        2026-09-04 * "滴滴" "打车" #reimbursed
          Assets:Receivable:Reimbursement  20.00 CNY
            category: "Expenses:Transit:Taxi"
          Assets:Bank
        2026-09-05 * "咖啡店" "美式"
          Expenses:Food:Drinks  25.00 CNY
          Assets:Bank

        """)
        XCTAssertTrue(L.errors.isEmpty, L.errors.map { $0.msg }.joined(separator: "; "))
        let D = Derived(L, today: "2026-10-01")
        let g = categoryGroups(D, root: "Expenses:")
        // closed accounts are not offered; the most used group first
        XCTAssertEqual(g.first?.id, "Expenses:Food")
        XCTAssertEqual(Set(g.map { $0.id }), ["Expenses:Food", "Expenses:Transit", "Expenses:Travel"])
        XCTAssertEqual(g.first?.accounts.first, "Expenses:Food:Dining")
        XCTAssertTrue(g.first { $0.id == "Expenses:Travel" }!.single)
        XCTAssertEqual(categoryGroups(D, root: "Income:").map { $0.id }, ["Income:Salary"])

        // a saved order is kept; groups that are new since go after it
        let o = orderedGroups(g, saved: ["Expenses:Travel", "Expenses:Gone", "Expenses:Food"])
        XCTAssertEqual(o.map { $0.id }, ["Expenses:Travel", "Expenses:Food", "Expenses:Transit"])

        // the newest use in each group, an advance's category included
        let last = lastUsedInGroups(L, root: "Expenses:")
        XCTAssertEqual(last["Expenses:Food"], "Expenses:Food:Drinks")
        XCTAssertEqual(last["Expenses:Transit"], "Expenses:Transit:Taxi")
        XCTAssertNil(last["Expenses:Travel"])
    }

    func testDefaultIcons() {
        XCTAssertEqual(defaultCategoryIcon("Expenses:Transit:Fuel"), "fuelpump")
        // an unknown leaf falls back to its group
        XCTAssertEqual(defaultCategoryIcon("Expenses:Transit:Ferry"), "car")
        XCTAssertEqual(defaultCategoryIcon("Expenses:Food"), "fork.knife")
        // income has its own meaning for the same word
        XCTAssertEqual(defaultCategoryIcon("Income:Gifts"), "envelope")
        XCTAssertEqual(defaultCategoryIcon("Expenses:Gifts"), "gift")
        XCTAssertEqual(defaultCategoryIcon("Expenses:Zzz"), "square.grid.2x2")
        XCTAssertEqual(defaultCategoryIcon("Income:Zzz"), "yensign.circle")
    }
}
