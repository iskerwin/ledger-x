import XCTest
@testable import LedgerKit

/// taking back a change the app made, also after other edits to the same file
final class UndoTests: XCTestCase {
    private let base = """
    2026-10-01 * "A" "one"
      Expenses:Food  10 CNY
      Assets:Bank

    2026-10-03 * "B" "three"
      Expenses:Food  30 CNY
      Assets:Bank

    2026-10-05 * "C" "five"
      Expenses:Food  50 CNY
      Assets:Bank

    """

    private func record(_ path: String, _ before: String?, _ after: String?) -> ChangeRecord {
        ChangeRecord(label: "t", files: [path], undo: revertOps(path: path, before: before, after: after))
    }

    private func undo(_ r: ChangeRecord, _ files: [String: String]) -> [String: String]? {
        guard case .success(let ops) = undoOps(r, current: { files[$0] }) else { return nil }
        var out = files
        for op in ops {
            if op.kind == .deleteFile { out[op.path] = nil; continue }
            out[op.path] = try? applyOps(out[op.path] ?? "", path: op.path, ops: [op], strict: true)
        }
        return out
    }

    func testHunks() {
        XCTAssertTrue(lineHunks(["a", "b"], ["a", "b"]).isEmpty)
        let h = lineHunks(["a", "b", "c", "d", "e"], ["a", "x", "c", "d", "e", "f"])
        XCTAssertEqual(h.map { [$0.a.lowerBound, $0.a.upperBound, $0.b.lowerBound, $0.b.upperBound] }, [[1, 2, 1, 2], [5, 5, 5, 6]])
    }

    func testUndoInsertAfterOtherEdits() {
        let after = insertEntry(base, "2026-10-02 * \"X\" \"two\"\n  Expenses:Food  20 CNY\n  Assets:Bank", "2026-10-02")
        let r = record("j.bean", base, after)
        XCTAssertEqual(undo(r, ["j.bean": after])?["j.bean"], base)
        // something else written to the file later stays
        let later = insertEntry(after, "2026-10-06 * \"Y\" \"six\"\n  Expenses:Food  60 CNY\n  Assets:Bank", "2026-10-06")
        let back = undo(r, ["j.bean": later])?["j.bean"] ?? ""
        XCTAssertFalse(back.contains("\"two\""))
        XCTAssertTrue(back.contains("\"six\""))
        XCTAssertEqual(back, insertEntry(base, "2026-10-06 * \"Y\" \"six\"\n  Expenses:Food  60 CNY\n  Assets:Bank", "2026-10-06"))
    }

    func testUndoEditAndDelete() {
        let edited = base.replacingOccurrences(of: "30 CNY", with: "33 CNY").replacingOccurrences(of: "\"five\"", with: "\"FIVE\"")
        let r = record("j.bean", base, edited)
        XCTAssertEqual(undo(r, ["j.bean": edited])?["j.bean"], base)
        // the edited entry was changed again since: refuse rather than guess
        let again = edited.replacingOccurrences(of: "33 CNY", with: "34 CNY")
        XCTAssertNil(undo(r, ["j.bean": again]))
        if case .failure(let p) = undoOps(r, current: { _ in again }) { XCTAssertEqual(p, .changedSince(path: "j.bean")) } else { XCTFail() }
        // a deleted entry comes back where it was
        let removed = removeBlock(base, "2026-10-03 * \"B\" \"three\"\n  Expenses:Food  30 CNY\n  Assets:Bank") ?? ""
        XCTAssertNotEqual(removed, base)
        XCTAssertEqual(undo(record("j.bean", base, removed), ["j.bean": removed])?["j.bean"], base)
    }

    func testRepeatedLines() {
        // identical entries: the context picks the right one
        let a = "2026-10-01 balance Assets:Bank  1 CNY\n\n2026-10-01 balance Assets:Bank  1 CNY\n\n; end\n"
        let b = "2026-10-01 balance Assets:Bank  1 CNY\n\n2026-10-01 balance Assets:Bank  2 CNY\n\n; end\n"
        XCTAssertEqual(undo(record("b.bean", a, b), ["b.bean": b])?["b.bean"], a)
        let c = "x\n\nx\n\nx\n"
        let d = "x\n\nx\n\nx\n\nx\n"
        XCTAssertEqual(undo(record("b.bean", c, d), ["b.bean": d])?["b.bean"], c)
    }

    func testNewAndDeletedFiles() {
        let r = record("2027.bean", nil, "2027-01-01 * \"A\"\n  Expenses:Food  1 CNY\n  Assets:Bank\n")
        XCTAssertEqual(r.undo.map { $0.kind }, [.deleteFile])
        XCTAssertEqual(undo(r, ["2027.bean": "2027-01-01 * \"A\"\n  Expenses:Food  1 CNY\n  Assets:Bank\n"])?["2027.bean"], nil)
        // more was written to the new file since: only this change's text is taken out
        let more = "2027-01-01 * \"A\"\n  Expenses:Food  1 CNY\n  Assets:Bank\n\n2027-01-02 * \"B\"\n  Expenses:Food  2 CNY\n  Assets:Bank\n"
        let left = undo(r, ["2027.bean": more])?["2027.bean"]
        XCTAssertNotNil(left)
        XCTAssertFalse(left?.contains("\"A\"") ?? true)
        XCTAssertTrue(left?.contains("\"B\"") ?? false)
        // a deleted file is written back, unless one was created there since
        let d = record("old.bean", "keep\n", nil)
        XCTAssertEqual(undo(d, [:])?["old.bean"], "keep\n")
        XCTAssertNil(undo(d, ["old.bean": "new"]))
        // shown as what was added / removed
        XCTAssertEqual(changeHunks(r).first?.added.first, "2027-01-01 * \"A\"")
    }

    func testRecordRoundTrip() throws {
        let r = record("j.bean", base, base + "\n; note\n")
        let data = try JSONEncoder().encode([r])
        XCTAssertEqual(try JSONDecoder().decode([ChangeRecord].self, from: data), [r])
        XCTAssertTrue(changeHunks(r).first?.added.contains("; note") ?? false)
        XCTAssertEqual(changeHunks(r).first?.removed, [])
    }
}
