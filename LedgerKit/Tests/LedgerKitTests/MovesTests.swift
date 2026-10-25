import XCTest
@testable import LedgerKit

/// a page showing a transaction follows it through links added, renames, edits and moves
final class MovesTests: XCTestCase {
    private let text = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank CNY
    2026-01-01 open Expenses:Food
    2026-01-01 open Expenses:Digital

    2026-10-01 * "Apple" "iCloud+"
      Expenses:Digital                                     6.00 CNY
      Assets:Bank                                         -6.00 CNY

    2026-10-02 * "饭店" "午饭"
      Expenses:Food                                       35.00 CNY
      Assets:Bank                                        -35.00 CNY

    """
    private func ledger() -> Ledger { loadLedger(root: "main.bean") { _ in self.text } }

    func testLinkAdded() throws {
        let L = ledger()
        let e = L.txns.first { $0.payee == "Apple" }!
        var op = Op(kind: .link, path: e.file)
        op.headerLine = e.startLine + 1
        op.header = e.src.components(separatedBy: "\n")[0]
        op.add = " ^sub-apple"; op.link = "sub-apple"
        let m = movedEntries([op], L)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.old, e.src)
        XCTAssertTrue(m.first!.new.hasPrefix("2026-10-01 * \"Apple\" \"iCloud+\" ^sub-apple\n"), m.first!.new)
        // the same as the file gets
        let file = try applyOps(text, path: e.file, ops: [op])
        XCTAssertTrue(file.contains(m.first!.new))
    }

    func testRenames() throws {
        let L = ledger()
        var p = Op(kind: .renamePayee, path: "main.bean"); p.old = "饭店"; p.text = "餐厅"
        var a = Op(kind: .rename, path: "main.bean"); a.old = "Expenses:Food"; a.text = "Expenses:Dining"
        let m = movedEntries([p, a], L)
        XCTAssertEqual(m.count, 1)
        XCTAssertTrue(m[0].new.contains("\"餐厅\"") && m[0].new.contains("Expenses:Dining"), m[0].new)
        XCTAssertTrue(try applyOps(text, path: "main.bean", ops: [p, a]).contains(m[0].new))
    }

    func testIdenticalCopyIsFollowedOnlyOnItsOwnLine() {
        let one = """
        2026-10-18 * "Transit" "Top-up"
          Expenses:Food                                       1.60 CNY
          Assets:Bank                                        -1.60 CNY
        """
        let text = """
        option "operating_currency" "CNY"
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Expenses:Food

        \(one)

        \(one)
        """
        let L = loadLedger(root: "main.bean") { _ in text }
        let second = L.txns[1]
        var op = Op(kind: .replace, path: second.file)
        op.old = second.src
        op.text = second.src.replacingOccurrences(of: "Top-up", with: "Ride")
        op.date = second.date
        op.anchorLine = second.line
        XCTAssertEqual(movedEntries([op], L).count, 1)
        op.anchorLine = 1
        XCTAssertTrue(movedEntries([op], L).isEmpty)
    }

    func testEditedAndMoved() {
        let L = ledger()
        let e = L.txns.first { $0.payee == "饭店" }!
        // to another day: a remove and an insert that says which entry it moves
        var rm = Op(kind: .remove, path: e.file); rm.old = e.src
        var ins = Op(kind: .insert, path: e.file)
        ins.date = "2026-10-05"
        ins.text = e.src.replacingOccurrences(of: "2026-10-02", with: "2026-10-05")
        ins.moves = e.src
        var m = movedEntries([rm, ins], L)
        XCTAssertEqual(m, [MovedEntry(oldDate: "2026-10-02", old: e.src, newDate: "2026-10-05", new: ins.text!)])
        // a new entry is not a move
        ins.moves = nil
        XCTAssertTrue(movedEntries([ins], L).isEmpty)
        // changed in place, then a link: followed through both
        var rp = Op(kind: .replace, path: e.file); rp.old = e.src; rp.date = e.date
        rp.text = e.src.replacingOccurrences(of: "午饭", with: "晚饭")
        var lk = Op(kind: .link, path: e.file)
        lk.headerLine = e.startLine + 1; lk.header = rp.text!.components(separatedBy: "\n")[0]; lk.add = " ^doc-x"
        m = movedEntries([rp, lk], L)
        XCTAssertEqual(m.count, 1)
        XCTAssertTrue(m[0].new.hasPrefix("2026-10-02 * \"饭店\" \"晚饭\" ^doc-x"), m[0].new)
    }
}

/// the lookup a detail page makes on every redraw, and the comparison under it
final class TxnLookupTests: XCTestCase {
    func testNormalisedTextIsTheSameAsLineByLineTrimming() {
        // what it was with a regular expression: trailing white space off each line, then off the whole
        func reference(_ s: String) -> String {
            s.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let samples = [
            "2026-10-01 * \"A\"  \n  Expenses:Food  1 CNY\t\n  Assets:Bank\n\n",
            "\n\n2026-10-01 * \"全角空格\"\u{3000}\n  Expenses:Food  1 CNY\u{00A0}\n",
            "2026-10-01 * \"Windows\"\r\n  Expenses:Food  1 CNY \r\n  Assets:Bank\r\n",
            "  leading kept inside\n    indented  \n",
            "", "   ", "\n", "a", "a \n b \n",
        ]
        for s in samples { XCTAssertEqual(normEntryText(s), reference(s), s.debugDescription) }
    }

    func testFindsATransactionWhereItWasMovedOrRewritten() throws {
        let text = """
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Expenses:Food

        2026-10-01 * "Apple" "iCloud+"
          Expenses:Food                                        6.00 CNY
          Assets:Bank                                         -6.00 CNY

        2026-10-02 * "饭店" "午饭"
          Expenses:Food                                       35.00 CNY
          Assets:Bank                                        -35.00 CNY

        """
        let L = loadLedger(root: "main.bean") { _ in text }
        let e = L.txns.first { $0.payee == "Apple" }!
        let lookup = TxnLookup(L)
        XCTAssertEqual(lookup.find(id: e.id, key: txnKey(e), moves: [:])?.src, e.src)
        // somewhere else in the list now (something inserted before it)
        XCTAssertEqual(lookup.find(id: 99, key: txnKey(e), moves: [:])?.src, e.src)
        XCTAssertNil(lookup.find(id: 99, key: "2026-10-03\u{1}nothing", moves: [:]))
        // a refund added its link: the page follows the move to the rewritten text
        var op = Op(kind: .link, path: e.file)
        op.headerLine = e.startLine + 1
        op.header = e.src.components(separatedBy: "\n")[0]
        op.add = " ^refund-apple"; op.link = "refund-apple"
        let m = try XCTUnwrap(movedEntries([op], L).first)
        let after = loadLedger(root: "main.bean") { _ in try applyOps(text, path: e.file, ops: [op]) }
        let moves = [normEntryText(m.oldDate + "\u{1}" + m.old): m.newDate + "\u{1}" + m.new]
        let found = TxnLookup(after).find(id: e.id, key: txnKey(e), moves: moves)
        XCTAssertEqual(found?.links, ["refund-apple"])
    }

    func testRowIdentityFollowsTheTextAndSeparatesIdenticalCopies() {
        let one = """
        2026-10-18 * "Transit" "Top-up"
          Expenses:Food                                       1.60 CNY
          Assets:Bank                                        -1.60 CNY
        """
        let text = """
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Expenses:Food

        \(one)

        \(one)
        """
        let L = loadLedger(root: "main.bean") { _ in text }
        let ts = L.txns
        XCTAssertEqual(ts.count, 2)
        XCTAssertEqual(txnRowID(ts[0], among: ts), txnKey(ts[0]) + "\u{2}0")
        XCTAssertEqual(txnRowID(ts[1], among: ts), txnKey(ts[1]) + "\u{2}1")
        XCTAssertNotEqual(txnRowID(ts[0], among: ts), txnRowID(ts[1], among: ts))
        XCTAssertEqual(txnRowID(ts[0], among: [ts[0]]), txnKey(ts[0]))
    }
}
