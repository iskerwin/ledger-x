import XCTest
@testable import LedgerKit

/// 批量编辑: the change to each transaction's text, and the Mac's write of several into a folder at once
final class BatchEditTests: XCTestCase {
    private var folder: URL!
    private let text = """
    option "operating_currency" "CNY"
    2023-01-01 open Assets:Bank
    2023-01-01 open Expenses:Food
    2023-01-01 open Expenses:Food:Snacks
    2023-01-01 open Expenses:Travel

    2026-01-05 * "Sample Diner" "Lunch"
      Expenses:Food           30.00 CNY
      Assets:Bank

    2026-01-06 * "Sample Shop" "Snacks" #trip
      Expenses:Food:Snacks    12.00 CNY
      Assets:Bank

    """

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private var ledger: Ledger { loadLedger(folder: folder)! }

    func testAnAccountIsReplacedExactlyNotItsSubAccounts() {
        let edit = BatchEdit.account(from: "Expenses:Food", to: "Expenses:Travel")
        let txns = ledger.txns
        XCTAssertEqual(edit.affected(txns), 1)
        XCTAssertNil(edit.applied(to: "2026-01-06 * \"Sample Shop\" \"Snacks\"\n  Expenses:Food:Snacks  12.00 CNY\n  Assets:Bank"))
        XCTAssertTrue(edit.applied(to: "2026-01-05 * \"Sample Diner\" \"Lunch\"\n  Expenses:Food  30.00 CNY\n  Assets:Bank")?.contains("Expenses:Travel") == true)
    }

    func testATagIsAddedOnlyWhereItIsMissing() {
        let edit = BatchEdit.tag(BatchEdit.word(" #trip "))
        XCTAssertEqual(edit, .tag("trip"))
        XCTAssertEqual(edit.affected(ledger.txns), 1)
        let header = edit.applied(to: "2026-01-05 * \"Sample Diner\" \"Lunch\"\n  Expenses:Food  30.00 CNY\n  Assets:Bank")?.components(separatedBy: "\n").first
        XCTAssertEqual(header?.hasSuffix("#trip"), true)
    }

    func testNotReadyWithoutWhatToChange() {
        XCTAssertFalse(BatchEdit.account(from: "Expenses:Food", to: "Expenses:Food").ready)
        XCTAssertFalse(BatchEdit.link("").ready)
        XCTAssertTrue(BatchEdit.link("trip-2026").ready)
    }

    func testOpsReadAsOneStep() {
        let ops = rewriteOps(ledger.txns, label: "Batch", lines: { _ in self.text.components(separatedBy: "\n") }, transform: BatchEdit.link("trip-2026").applied(to:))
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(ops.compactMap(\.label), ["Batch"])
        XCTAssertEqual(ops.filter { $0.silent == true }.count, 1)
    }

    func testTheFolderGetsEveryChangeAtOnce() throws {
        let save = try prepareFolderBatch(ledger.txns, .link("trip-2026"), label: "Batch", folder: folder).get()
        try commitFolderSave(save, folder: folder)
        XCTAssertTrue(ledger.txns.allSatisfy { $0.links.contains("trip-2026") })
    }

    func testNothingToChangeWritesNothing() {
        XCTAssertThrowsError(try prepareFolderBatch(ledger.txns, .account(from: "Expenses:Missing", to: "Expenses:Travel"), label: "Batch", folder: folder).get())
    }
}
