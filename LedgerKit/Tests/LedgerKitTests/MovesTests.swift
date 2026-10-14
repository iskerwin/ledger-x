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

    func testLinkAdded() {
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
        let file = applyOps(text, path: e.file, ops: [op])
        XCTAssertTrue(file.contains(m.first!.new))
    }

    func testRenames() {
        let L = ledger()
        var p = Op(kind: .renamePayee, path: "main.bean"); p.old = "饭店"; p.text = "餐厅"
        var a = Op(kind: .rename, path: "main.bean"); a.old = "Expenses:Food"; a.text = "Expenses:Dining"
        let m = movedEntries([p, a], L)
        XCTAssertEqual(m.count, 1)
        XCTAssertTrue(m[0].new.contains("\"餐厅\"") && m[0].new.contains("Expenses:Dining"), m[0].new)
        XCTAssertTrue(applyOps(text, path: "main.bean", ops: [p, a]).contains(m[0].new))
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
