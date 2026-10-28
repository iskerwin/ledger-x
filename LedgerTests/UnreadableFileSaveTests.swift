import XCTest
@testable import Ledger
import LedgerKit

/// Saving ledger-x.json (or a .bql file) remembers the text it replaces, so a change from another device
/// is merged, not overwritten. When that file is in the ledger but can't be read now, nothing is saved.
@MainActor
final class UnreadableFileSaveTests: XCTestCase {
    private let source = """
    2026-01-01 open Assets:Cash CNY

    """

    func testAFileThatCannotBeReadIsNotOverwritten() async throws {
        let store = Store()
        var config = RepoConfig()
        config.id = "unreadable-test-" + UUID().uuidString
        config.kind = .local
        config.folderName = config.id
        let root = FolderBackend.localRoot(config.folderName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { @MainActor in try? FileManager.default.removeItem(at: root) }
        try source.write(to: root.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        let shared = root.appendingPathComponent(LedgerXConfig.path)
        try #"{"version":1}"#.write(to: shared, atomically: true, encoding: .utf8)
        store.cfg = config
        store.mainFile = "main.bean"
        await store.refresh()
        let readable = await store.fileWriteOp(LedgerXConfig.path, text: "{}")
        XCTAssertEqual(readable?.old, #"{"version":1}"#, "a readable file is remembered")

        // the file is still in the ledger, but its text is neither cached nor readable now
        let sha = try XCTUnwrap(store.tree?.files[LedgerXConfig.path])
        BlobCache.remove(sha)
        try FileManager.default.removeItem(at: shared)
        let op = await store.fileWriteOp(LedgerXConfig.path, text: "{}")
        XCTAssertNil(op)
        let saved = await store.saveRepoConfig(LedgerXConfig())
        XCTAssertFalse(saved)
        XCTAssertTrue(store.pending.isEmpty, "nothing is queued to overwrite it")
    }
}
