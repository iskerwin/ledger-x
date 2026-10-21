import XCTest
@testable import LedgerKit

final class BuildReuseTests: XCTestCase {
    private func insert(_ text: String, path: String) -> Op {
        var op = Op(kind: .insert, path: path)
        op.text = text
        op.date = "2026-10-02"
        return op
    }

    func testReusesBuiltLedgerWhenTheQueueIsNotEmpty() {
        let op = insert("2026-10-02 * \"Shop\" \"\"\n  Expenses:Food  3.00 CNY\n  Assets:Cash", path: "2026.bean")
        let built = LedgerBuildKey(files: ["2026.bean": "abc"], ops: [op])
        XCTAssertTrue(canReuseBuiltLedger(built: built, complete: true, files: ["2026.bean": "abc"], ops: [op]))
    }

    func testDoesNotReuseADifferentQueueOrAnIncompleteDownload() {
        var pushed = insert("2026-10-02 * \"Shop\" \"\"\n  Expenses:Food  3.00 CNY\n  Assets:Cash", path: "2026.bean")
        var held = pushed
        held.held = "kept on this phone"
        let files = ["2026.bean": "abc"]
        let built = LedgerBuildKey(files: files, ops: [pushed, held])
        XCTAssertFalse(canReuseBuiltLedger(built: built, complete: true, files: files, ops: [pushed]))
        XCTAssertFalse(canReuseBuiltLedger(built: built, complete: true, files: ["2026.bean": "def"], ops: [pushed, held]))
        XCTAssertFalse(canReuseBuiltLedger(built: built, complete: false, files: files, ops: [pushed, held]))
        XCTAssertFalse(canReuseBuiltLedger(built: nil, complete: true, files: files, ops: []))
        XCTAssertTrue(canReuseBuiltLedger(built: LedgerBuildKey(files: files, ops: []), complete: true, files: files, ops: []))
    }

    func testSyncTextsMatchAfterTheQueueBecomesFileContent() {
        let path = "2026.bean"
        let base = "2026-10-01 * \"Old\" \"\"\n  Expenses:Food  1.00 CNY\n  Assets:Cash\n"
        let entry = "2026-10-02 * \"Shop\" \"\"\n  Expenses:Food  3.00 CNY\n  Assets:Cash\n"
        let op = insert(entry, path: path)
        let pushed = (try? applyOps(base, path: path, ops: [op])) ?? ""
        XCTAssertTrue(ledgerTextsMatch(paths: [path], oldTexts: [path: base], newTexts: [path: pushed], oldOps: [op], newOps: []))
        XCTAssertFalse(ledgerTextsMatch(paths: [path], oldTexts: [path: base], newTexts: [path: pushed + "\n; remote\n"], oldOps: [op], newOps: []))
    }

    func testHeldOperationStillHasToMatchOnBothSides() {
        let path = "2026.bean"
        var held = insert("2026-10-03 * \"Held\" \"\"\n  Expenses:Food  4.00 CNY\n  Assets:Cash\n", path: path)
        held.held = "kept on this phone"
        let base = "2026-10-01 * \"Old\" \"\"\n  Expenses:Food  1.00 CNY\n  Assets:Cash\n"
        XCTAssertTrue(ledgerTextsMatch(paths: [path], oldTexts: [path: base], newTexts: [path: base], oldOps: [held], newOps: [held]))
        XCTAssertFalse(ledgerTextsMatch(paths: [path], oldTexts: [path: base], newTexts: [path: base], oldOps: [held], newOps: []))
    }
}
