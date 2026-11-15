import XCTest
@testable import LedgerKit

/// The Mac's 调整当天顺序: one day's entries of a file trade places; what lies between them stays put
final class FolderReorderTests: XCTestCase {
    private var folder: URL!
    private let journal = """
    2026-03-01 * "Bakery" "Bread"
      Expenses:Food  12.00 CNY
      Assets:Bank

    2026-03-02 balance Assets:Bank  988.00 CNY

    2026-03-02 * "Cafe" "Coffee"
      Expenses:Food  30.00 CNY
      Assets:Bank

    ; lunch after coffee
    2026-03-02 * "Noodles" "Lunch"
      Expenses:Food  25.00 CNY
      Assets:Bank

    2026-03-02 * "Market" "Fruit"
      Expenses:Food  18.00 CNY
      Assets:Bank

    """

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("journals"), withIntermediateDirectories: true)
        try """
        include "journals/2026.bean"
        2025-01-01 open Assets:Bank CNY
        2025-01-01 open Expenses:Food CNY
        2025-01-01 open Equity:Opening CNY
        2026-01-01 * "Opening"
          Assets:Bank  1000.00 CNY
          Equity:Opening  -1000.00 CNY

        """.write(to: folder.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        try journal.write(to: folder.appendingPathComponent("journals/2026.bean"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func day() throws -> [Entry] {
        let ledger = try XCTUnwrap(loadLedger(folder: folder))
        return ledger.txns.filter { $0.date == "2026-03-02" && $0.file == "journals/2026.bean" }.sorted { $0.startLine < $1.startLine }
    }

    private func text() throws -> String {
        try String(contentsOf: folder.appendingPathComponent("journals/2026.bean"), encoding: .utf8)
    }

    func testTheDayIsWrittenInTheNewOrderAndWhatLiesBetweenStays() throws {
        let entries = try day()
        XCTAssertEqual(entries.map(\.payee), ["Cafe", "Noodles", "Market"])
        let save = try prepareFolderReorder([entries[2], entries[0], entries[1]], folder: folder).get()
        XCTAssertTrue(save.issues.isEmpty)
        try commitFolderSave(save, folder: folder)
        XCTAssertEqual(try day().map(\.payee), ["Market", "Cafe", "Noodles"])
        let written = try text()
        // the comment and the blank lines keep their places; the other day and the assertion are untouched
        XCTAssertTrue(written.hasPrefix(journal.components(separatedBy: "2026-03-02 * \"Cafe\"")[0]))
        let market = try XCTUnwrap(written.range(of: "\"Market\"")), comment = try XCTUnwrap(written.range(of: "; lunch after coffee"))
        let cafe = try XCTUnwrap(written.range(of: "\"Cafe\""))
        XCTAssertLessThan(market.lowerBound, comment.lowerBound)
        XCTAssertLessThan(comment.lowerBound, cafe.lowerBound)
        XCTAssertEqual(written.count, journal.count)
    }

    func testAnEntryChangedSinceIsRefusedAndNothingIsWritten() throws {
        let entries = try day()
        try journal.replacingOccurrences(of: "\"Noodles\" \"Lunch\"", with: "\"Noodles\" \"Dinner\"")
            .write(to: folder.appendingPathComponent("journals/2026.bean"), atomically: true, encoding: .utf8)
        let before = try text()
        guard case .failure = prepareFolderReorder([entries[1], entries[0], entries[2]], folder: folder) else {
            return XCTFail("an entry that is no longer in the file must refuse the reorder")
        }
        XCTAssertEqual(try text(), before)
    }

    func testEntriesOfAnotherDayOrFileAreRefused() throws {
        let ledger = try XCTUnwrap(loadLedger(folder: folder))
        let bakery = try XCTUnwrap(ledger.txns.first { $0.payee == "Bakery" })
        guard case .failure = prepareFolderReorder([try day()[0], bakery], folder: folder) else {
            return XCTFail("entries of different days are not one day's order")
        }
    }
}
