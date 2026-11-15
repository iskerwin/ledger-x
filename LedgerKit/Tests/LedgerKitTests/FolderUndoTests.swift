import XCTest
@testable import LedgerKit

/// 编辑 › 撤销 / 重做 on the Mac: a written save put back and done again, only while the folder is as it left it
final class FolderUndoTests: XCTestCase {
    private var folder: URL!
    private let opens = """
    include "journals/2026.bean"
    2025-01-01 open Assets:Bank CNY
    2025-01-01 open Expenses:Food CNY
    2025-01-01 open Equity:Opening CNY

    """
    private let journal = """
    2026-01-01 * "Opening"
      Assets:Bank  1000.00 CNY
      Equity:Opening  -1000.00 CNY

    """

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("main.bean", opens)
        try write("journals/2026.bean", journal)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path)
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

    private func save(_ draft: Draft) throws -> FolderChange {
        try commitFolderSave(try prepareFolderSave(draft, folder: folder).get(), folder: folder)
    }

    func testAnEntryIsPutBackAndWrittenAgain() throws {
        let change = try save(expense("2026-03-01"))
        let written = try read("journals/2026.bean")
        XCTAssertNotEqual(written, journal)
        let redo = try undoFolderChange(change, folder: folder)
        XCTAssertEqual(try read("journals/2026.bean"), journal)
        XCTAssertEqual(try XCTUnwrap(loadLedger(folder: folder)).txns.map(\.narration), ["Opening"])
        let again = try redoFolderChange(redo, folder: folder)
        XCTAssertEqual(try read("journals/2026.bean"), written)
        try undoFolderChange(again, folder: folder)
        XCTAssertEqual(try read("journals/2026.bean"), journal)
    }

    func testANewFileAndItsIncludeGoAway() throws {
        let change = try save(expense("2027-01-05"))
        XCTAssertTrue(exists("journals/2027.bean"))
        XCTAssertTrue(try read("main.bean").contains("journals/2027.bean"))
        try undoFolderChange(change, folder: folder)
        XCTAssertFalse(exists("journals/2027.bean"))
        XCTAssertEqual(try read("main.bean"), opens)
    }

    func testAFileChangedSinceIsNotUndone() throws {
        let change = try save(expense("2026-03-01"))
        let changed = try read("journals/2026.bean") + "\n; edited elsewhere\n"
        try write("journals/2026.bean", changed)
        XCTAssertThrowsError(try undoFolderChange(change, folder: folder))
        XCTAssertEqual(try read("journals/2026.bean"), changed)
    }

    func testRedoIsRefusedOnceTheFileChanged() throws {
        let redo = try undoFolderChange(try save(expense("2026-03-01")), folder: folder)
        try write("journals/2026.bean", journal + "; edited elsewhere\n")
        XCTAssertThrowsError(try redoFolderChange(redo, folder: folder))
        XCTAssertEqual(try read("journals/2026.bean"), journal + "; edited elsewhere\n")
    }

    func testAnAttachmentGoesWithItsLineAndComesBack() throws {
        _ = try save(expense("2026-03-01"))
        let entry = try XCTUnwrap(loadLedger(folder: folder)?.txns.first { $0.narration == "Sample" })
        let jpg = Data([0xFF, 0xD8, 0xFF])
        let change = try commitFolderSave(try prepareFolderAttachment(entry, data: jpg, ext: "jpg", folder: folder).get(), folder: folder)
        let blob = try XCTUnwrap(change.blobs.first?.path)
        let redo = try undoFolderChange(change, folder: folder)
        XCTAssertFalse(exists(blob))
        XCTAssertTrue(try XCTUnwrap(loadLedger(folder: folder)).documents.isEmpty)
        try redoFolderChange(redo, folder: folder)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(blob)), jpg)
        XCTAssertEqual(try XCTUnwrap(loadLedger(folder: folder)).documents.count, 1)
    }

    func testADeletedDocumentComesBackFromTheTrash() throws {
        let pdf = Data("%PDF".utf8)
        try commitFolderSave(try prepareFolderStatement(account: "Assets:Bank", date: "2026-10-31", data: pdf, ext: "pdf", folder: folder).get(), folder: folder)
        let item = try XCTUnwrap(documentItems(try XCTUnwrap(loadLedger(folder: folder))).first)
        let path = try XCTUnwrap(item.entry.path.flatMap { documentPath($0, from: item.entry.file) })
        let deleted = try deleteFolderDocument(item.entry, file: true, folder: folder)
        XCTAssertEqual(deleted.outcome, .trashed)
        XCTAssertFalse(exists(path))
        let redo = try undoFolderChange(deleted.change, folder: folder)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(path)), pdf)
        XCTAssertEqual(documentItems(try XCTUnwrap(loadLedger(folder: folder))).count, 1)
        try redoFolderChange(redo, folder: folder)
        XCTAssertFalse(exists(path))
        XCTAssertTrue(documentItems(try XCTUnwrap(loadLedger(folder: folder))).isEmpty)
    }

    /// several files added at once are one step: each file goes back to what it was before the first
    func testSavesMergedAreUndoneAsOne() throws {
        let first = try save(expense("2026-03-01"))
        let second = try save(expense("2026-03-02"))
        try undoFolderChange(.merged([first, second]), folder: folder)
        XCTAssertEqual(try read("journals/2026.bean"), journal)
    }
}
