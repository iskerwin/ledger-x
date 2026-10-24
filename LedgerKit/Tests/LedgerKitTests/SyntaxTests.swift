import XCTest
@testable import LedgerKit

/// Beancount syntax the app has to read like bean-check does
final class SyntaxTests: XCTestCase {
    func testTagsAndLinksOnTheirOwnLine() {
        let L = loadLedger(root: "main.bean") { _ in """
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Expenses:Food

        2026-10-01 * "饭店" "午饭" #lunch
          #trip ^reimburse-co-20261001
          #lunch
          Expenses:Food  30.00 CNY
          Assets:Bank

        """ }
        XCTAssertTrue(L.errors.isEmpty, L.errors.map { $0.msg }.joined(separator: "; "))
        let t = L.txns.last!
        XCTAssertEqual(t.tags, ["lunch", "trip"])
        XCTAssertEqual(t.links, ["reimburse-co-20261001"])
        XCTAssertEqual(t.postings.count, 2)
    }

    /// Inside quotes Beancount turns only \" into "; \\, \n and \t stay as they are written (bean-check 3: the
    /// narration below reads `say "hi" a\\b tab\tx`). Text the app writes reads back the same.
    func testOnlyAnEscapedQuoteIsUnescaped() {
        let L = loadLedger(root: "main.bean") { _ in #"""
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Expenses:Food
        2026-01-02 * "Pay\"ee" "say \"hi\" a\\b tab\tx"
          Expenses:Food  1.00 CNY
          Assets:Bank
        """# }
        XCTAssertTrue(L.errors.isEmpty, L.errors.map { $0.msg }.joined(separator: "; "))
        XCTAssertEqual(L.txns.first?.payee, "Pay\"ee")
        XCTAssertEqual(L.txns.first?.narration, #"say "hi" a\\b tab\tx"#)
        // a backslash typed in the app is written as it is, only quotes are escaped
        XCTAssertEqual(quoted(#"C:\files "x""#), #""C:\files \"x\"""#)
    }

    func testIncludeWildcards() {
        let files: [String: String] = [
            "main.bean": "include \"accounts.bean\"\ninclude \"journals/*.bean\"\ninclude \"more/**/*.bean\"\n",
            "accounts.bean": "2025-01-01 open Assets:Bank CNY\n2025-01-01 open Expenses:Food\n",
            "journals/2025.bean": "2025-05-01 * \"a\"\n  Expenses:Food  1.00 CNY\n  Assets:Bank\n",
            "journals/2026.bean": "2026-05-01 * \"b\"\n  Expenses:Food  2.00 CNY\n  Assets:Bank\n",
            "journals/notes.txt": "not a ledger",
            "more/x/deep.bean": "2026-06-01 * \"c\"\n  Expenses:Food  3.00 CNY\n  Assets:Bank\n",
            "more/top.bean": "2026-07-01 * \"d\"\n  Expenses:Food  4.00 CNY\n  Assets:Bank\n",
        ]
        let L = loadLedger(root: "main.bean", listFiles: { Array(files.keys) }) { p in
            guard let t = files[p] else { throw NSError(domain: "x", code: 1) }
            return t
        }
        XCTAssertTrue(L.errors.isEmpty, L.errors.map { $0.msg }.joined(separator: "; "))
        XCTAssertEqual(L.txns.map { $0.payee.isEmpty ? $0.narration : $0.payee }.sorted(), ["a", "b", "c", "d"])
        XCTAssertTrue(globMatch("journals/*.bean", "journals/2026.bean"))
        XCTAssertFalse(globMatch("journals/*.bean", "journals/sub/2026.bean"))
        XCTAssertTrue(globMatch("**/*.bean", "a/b/c.bean"))
        XCTAssertTrue(globMatch("**/*.bean", "c.bean"))
        XCTAssertTrue(globMatch("j/202[56].bean", "j/2025.bean"))
        XCTAssertFalse(globMatch("j/202[!56].bean", "j/2025.bean"))
        // without a file list a wildcard can't be expanded: said so, not silently skipped
        let M = loadLedger(root: "main.bean") { p in files[p] ?? "" }
        XCTAssertTrue(M.errors.contains { $0.msg.contains("include") })
    }
}
