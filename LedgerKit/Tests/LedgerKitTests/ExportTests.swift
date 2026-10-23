import XCTest
@testable import LedgerKit

/// Exported CSV opens in a spreadsheet: text that would run as a formula there (a payee from an imported statement
/// or a scan) is kept as text; amounts stay numbers.
final class ExportTests: XCTestCase {
    func testTextThatLooksLikeAFormulaIsExportedAsText() {
        let L = loadLedger(root: "main.bean") { _ in #"""
        2026-01-01 open Assets:Cash CNY
        2026-01-01 open Expenses:Food CNY
        2026-10-24 * "=HYPERLINK(1)" "@SUM(A1)"
          Expenses:Food   12.50 CNY
          Assets:Cash
        """# }
        let csv = exportCSV(L)
        XCTAssertTrue(csv.contains(",'=HYPERLINK(1),'@SUM(A1),"), csv)
        XCTAssertTrue(csv.contains(",-12.5,"), "a negative amount is still a number: \(csv)")
        XCTAssertEqual(csvCell("+86 138"), "'+86 138")
        XCTAssertEqual(csvCell("-3.25"), "-3.25")
        XCTAssertEqual(csvCell("Coffee"), "Coffee")
        XCTAssertEqual(csvCell(#"=A1,"x""#), #""'=A1,""x""""#)
    }
}
