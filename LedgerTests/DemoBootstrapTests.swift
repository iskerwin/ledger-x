import XCTest
@testable import Ledger
import LedgerKit

@MainActor
final class DemoBootstrapTests: XCTestCase {
    func testDemoFixtureDoesNotInheritThePreviousLedgersFilesOrPendingChanges() async throws {
        let text = """
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Expenses:Food CNY
        2026-10-17 * "Cafe" "Coffee"
          Expenses:Food 12 CNY
          Assets:Bank -12 CNY
        """
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try text.write(to: folder.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        let store = Store()
        var previous = RepoConfig()
        previous.id = "demo-bootstrap-previous-" + UUID().uuidString
        previous.kind = .local
        previous.folderName = previous.id
        let previousFolder = FolderBackend.localRoot(previous.folderName)
        try FileManager.default.createDirectory(at: previousFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: previousFolder) }
        try text.replacingOccurrences(of: "Coffee", with: "Coffee in the previous ledger")
            .write(to: previousFolder.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        store.cfg = previous
        store.pending = []
        store.mainFile = "main.bean"
        await store.refresh()
        XCTAssertNotNil(store.tree)
        var stale = Op(kind: .write, path: "main.bean")
        stale.text = text.replacingOccurrences(of: "Coffee", with: "Coffee from the previous save")
        store.pending = [stale]
        store.mainFile = "previous.bean"
        store.journalPattern = "old/{year}.bean"
        store.receivableAccount = "Assets:Receivable:OldTest"
        store.subsFile = "previous-subscriptions.bean"

        await store.loadDemo(folder.path)

        XCTAssertNotEqual(store.cfg.id, previous.id)
        XCTAssertNotEqual(store.cfg.id, "default", "test saves must not reuse the first real ledger's preferences")
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertNil(store.tree)
        XCTAssertEqual(store.main, "main.bean")
        XCTAssertTrue(store.journalPattern.isEmpty)
        XCTAssertTrue(store.receivableAccount.isEmpty)
        XCTAssertTrue(store.subsFile.isEmpty)
        let read = try await store.fileText("main.bean")
        XCTAssertEqual(read, text)
        let entry = try XCTUnwrap(store.L?.txns.first { $0.payee == "Cafe" })
        let located = await store.locatedSource(entry)
        XCTAssertEqual(located?.text, entry.src)
        let result = await store.beginEdit(entry)
        XCTAssertEqual(result, .opened)
        XCTAssertTrue(store.adding)
        XCTAssertEqual(store.draft.replacing?.old, entry.src)
    }
}
