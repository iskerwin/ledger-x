import XCTest
@testable import LedgerKit

final class FolderLedgersTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("main.bean", """
        include "journals/*.bean"
        2025-01-01 open Assets:Bank CNY
        2025-01-01 open Expenses:Food CNY
        2025-01-01 open Equity:Opening CNY

        2025-01-01 * "Opening"
          Assets:Bank  1000.00 CNY
          Equity:Opening  -1000.00 CNY

        """)
        try write("journals/2025.bean", txn("2025-03-01", "Main"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func txn(_ date: String, _ narration: String) -> String {
        "\(date) * \"\(narration)\"\n  Assets:Bank  -10.00 CNY\n  Expenses:Food  10.00 CNY\n\n"
    }

    private func expense(_ date: String) -> Draft {
        var draft = Draft()
        draft.kind = .expense
        draft.date = date
        draft.payee = "Sample Shop"
        draft.narration = "Sample"
        draft.amount = "35"
        draft.currency = "CNY"
        draft.funding = "Assets:Bank"
        draft.account = "Expenses:Food"
        return draft
    }

    private func same(_ kept: Ledger, _ fresh: Ledger, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(kept.files, fresh.files, file: file, line: line)
        XCTAssertEqual(kept.entries.map(\.src), fresh.entries.map(\.src), file: file, line: line)
        XCTAssertEqual(kept.errors.map(\.msg), fresh.errors.map(\.msg), file: file, line: line)
        XCTAssertEqual(kept.final, fresh.final, file: file, line: line)
    }

    /// The window has the ledger; saving used to parse it again from disk, then what it would write, and the reading the
    /// write set off parsed it a third time
    func testSavingAnEntryParsesTheFolderOnce() throws {
        let window = try XCTUnwrap(loadLedger(folder: folder))
        let parses = FolderLedgers.parses
        let save = try prepareFolderSave(expense("2026-04-01"), folder: folder).get()
        XCTAssertEqual(save.issues, [])
        try commitFolderSave(save, folder: folder)
        let reloaded = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertEqual(FolderLedgers.parses - parses, 1)
        XCTAssertFalse(reloaded === window)
        XCTAssertEqual(reloaded.txns.count, window.txns.count + 1)
        same(reloaded, readFolderLedger(root: "main.bean", folder: folder).ledger)
    }

    func testAnUnchangedFolderGivesTheSameLedgerBack() throws {
        let first = try XCTUnwrap(loadLedger(folder: folder))
        let parses = FolderLedgers.parses
        XCTAssertTrue(try XCTUnwrap(loadLedger(folder: folder)) === first)
        XCTAssertEqual(FolderLedgers.parses, parses)
    }

    func testAChangeOfTheSameLengthIsReadAgain() throws {
        let first = try XCTUnwrap(loadLedger(folder: folder))
        try write("journals/2025.bean", txn("2025-03-01", "Mbin"))
        let second = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertFalse(second === first)
        XCTAssertEqual(second.txns.map(\.narration), ["Opening", "Mbin"])
    }

    func testANewFileTheWildcardTakesIsReadAgain() throws {
        let first = try XCTUnwrap(loadLedger(folder: folder))
        try write("journals/2026.bean", txn("2026-03-01", "New"))
        let second = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertFalse(second === first)
        XCTAssertEqual(Set(second.txns.map(\.narration)), ["Opening", "Main", "New"])
    }

    func testAnIncludedFileThatAppearsIsReadAgain() throws {
        try write("main.bean", "include \"extra.bean\"\n2025-01-01 open Assets:Bank CNY\n2025-01-01 open Expenses:Food CNY\n")
        let first = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertFalse(first.errors.isEmpty)
        XCTAssertTrue(try XCTUnwrap(loadLedger(folder: folder)) === first)
        try write("extra.bean", txn("2025-03-01", "Extra"))
        let second = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertEqual(second.txns.map(\.narration), ["Extra"])
    }

    func testAnotherMainFileIsReadAgain() throws {
        let first = try XCTUnwrap(loadLedger(folder: folder))
        try write("books/root.bean", txn("2025-03-01", "Root"))
        try write(LedgerXConfig.path, #"{"main": "books/root.bean"}"#)
        let second = try XCTUnwrap(loadLedger(folder: folder))
        XCTAssertFalse(second === first)
        XCTAssertEqual(second.txns.map(\.narration), ["Root"])
    }

    /// LedgerKit's messages (errors, checks) are in the language shown: the other language reads the folder again
    func testAnotherLanguageIsReadAgain() throws {
        let chinese = KitLocale.chinese
        defer { KitLocale.chinese = chinese }
        KitLocale.chinese = true
        let first = try XCTUnwrap(loadLedger(folder: folder))
        KitLocale.chinese = false
        XCTAssertFalse(try XCTUnwrap(loadLedger(folder: folder)) === first)
    }

    /// a reading asked for during another waits for it, and one cancelled while it waits doesn't run
    func testSerialWorkRunsOneAtATimeAndSkipsTheCancelled() async {
        let serial = SerialWork()
        let started = expectation(description: "first started")
        let release = DispatchSemaphore(value: 0)
        let counts = Counts()
        let first = Task { await serial.run { counts.enter(); started.fulfill(); release.wait(); counts.leave(); return 1 } }
        await fulfillment(of: [started], timeout: 10)
        let skipped = Task { await serial.run { counts.enter(); counts.leave(); return 2 } }
        skipped.cancel()
        let last = Task { await serial.run { counts.enter(); counts.leave(); return 3 } }
        release.signal()
        let results = (await first.value, await skipped.value, await last.value)
        XCTAssertEqual(results.0, 1)
        XCTAssertNil(results.1)
        XCTAssertEqual(results.2, 3)
        XCTAssertEqual(counts.runs, 2)
        XCTAssertEqual(counts.most, 1)
    }
}

private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private(set) var runs = 0
    private(set) var most = 0
    func enter() { lock.lock(); now += 1; runs += 1; most = max(most, now); lock.unlock() }
    func leave() { lock.lock(); now -= 1; lock.unlock() }
}
