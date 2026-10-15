import XCTest
@testable import LedgerKit

/// the source editor's shortcuts that work on the entry around the cursor
final class EditorActionsTests: XCTestCase {
    private let text = """
    2026-10-13 * "快餐店" "可乐"
      Expenses:Food:Drinks   4.00 CNY
      Assets:Bank:BOC

    2026-10-14 ! "星河" "工资补发"
      Assets:Bank:BOC    1460.00 CNY
      Assets:Receivable:Employer

    """

    private func at(_ s: String) -> Int { (text as NSString).range(of: s).location }

    func testEntryRange() {
        let ns = text as NSString
        let r = entryRange(text, at: at("Drinks"))!
        XCTAssertTrue(ns.substring(with: r).hasPrefix("2026-10-13"))
        XCTAssertTrue(ns.substring(with: r).hasSuffix("Assets:Bank:BOC\n"))
        XCTAssertNil(entryRange(text, at: at("\n\n2026-10-14") + 1))
    }

    func testToggleFlag() {
        var t = toggledFlag(text, at: at("Drinks"))!
        XCTAssertEqual(t.with, "!")
        XCTAssertEqual((text as NSString).substring(with: t.range), "*")
        t = toggledFlag(text, at: at("工资"))!
        XCTAssertEqual(t.with, "*")
        XCTAssertNil(toggledFlag("  Assets:Cash", at: 3))
    }

    func testAlign() {
        let a = alignedEntry(text, at: at("可乐"))!
        XCTAssertTrue(a.with.contains("Expenses:Food:Drinks") && a.with.hasSuffix("\n"))
        XCTAssertTrue(a.with.components(separatedBy: "\n")[1].hasSuffix("4.00 CNY"))
        XCTAssertNotEqual(a.with, (text as NSString).substring(with: a.range))
    }

    func testTemplate() {
        let t = transactionTemplate(date: "2026-10-15")
        XCTAssertEqual(t.text, "2026-10-15 * \"\" \"\"\n  \n  ")
        XCTAssertEqual(t.cursor, 14)
    }
}
