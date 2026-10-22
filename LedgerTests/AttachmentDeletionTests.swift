import XCTest
@testable import Ledger
import LedgerKit

/// 移除并删除文件 against a local folder ledger: the file goes only after its record's removal has synced,
/// a copy stays on the device, and 撤回 puts both back. Fictional data only.
@MainActor
final class AttachmentDeletionTests: XCTestCase {
    private let path = "documents/receipts/receipts_20261019.jpg"
    private let bytes = Data([0xFF, 0xD8, 0xFF, 0x00, 0x42])

    private func fixture(documents: [String]) async throws -> (Store, URL) {
        let store = Store()
        var config = RepoConfig()
        config.id = "attachment-delete-test-" + UUID().uuidString
        config.kind = .local
        config.folderName = config.id
        let root = FolderBackend.localRoot(config.folderName)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("documents/receipts"), withIntermediateDirectories: true)
        try bytes.write(to: root.appendingPathComponent(path))
        let text = (["2026-01-01 open Assets:Bank:DemoBank CNY"] + documents).joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        store.cfg = config
        store.pending = []
        store.mainFile = "main.bean"
        await store.refresh()
        addTeardownBlock { @MainActor in
            await store.waitForSavedSync()
            for item in store.deletedAttachments(ledger: config.id) {
                try? RecoveryFiles.removeData(kind: "deleted-attachment-" + item.id.uuidString, ledger: config.id)
            }
            try? RecoveryFiles.remove(kind: "deleted-attachments", ledger: config.id)
            try? FileManager.default.removeItem(at: root)
        }
        return (store, root)
    }

    private func document(_ date: String) -> String {
        "\(date) document Assets:Bank:DemoBank \"\(path)\""
    }

    func testDeletingTheFileKeepsACopyAndUndoPutsBothBack() async throws {
        let (store, root) = try await fixture(documents: [document("2026-10-19")])
        let file = root.appendingPathComponent(path)
        let entry = try XCTUnwrap(store.L?.documents.first)
        let deleted = await store.deleteDocument(entry, file: true, summary: "test")
        XCTAssertTrue(deleted)
        await store.waitForSavedSync()
        await store.finishAttachmentDeletions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let item = try XCTUnwrap(store.deletedAttachments().first)
        XCTAssertEqual(item.state, .deleted)
        XCTAssertEqual(item.path, path)
        XCTAssertTrue(store.L?.documents.isEmpty ?? false)

        let record = try XCTUnwrap(item.record)
        let reverted = await store.revert(record)
        XCTAssertTrue(reverted)
        await store.waitForSavedSync()
        await store.refresh()
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(store.L?.documents.count, 1)
        XCTAssertTrue(store.deletedAttachments().isEmpty)
    }

    func testRecentlyDeletedRestoresThroughItsRecord() async throws {
        let (store, root) = try await fixture(documents: [document("2026-10-19")])
        let entry = try XCTUnwrap(store.L?.documents.first)
        let deleted = await store.deleteDocument(entry, file: true, summary: "test")
        XCTAssertTrue(deleted)
        await store.waitForSavedSync()
        await store.finishAttachmentDeletions()
        let item = try XCTUnwrap(store.deletedAttachments().first)
        let recovered = await store.recoverDeletedAttachment(item.id)
        XCTAssertTrue(recovered)
        await store.waitForSavedSync()
        await store.refresh()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        XCTAssertEqual(store.L?.documents.count, 1)
        XCTAssertTrue(store.deletedAttachments().isEmpty)
        XCTAssertNotNil(store.history.first { $0.id == item.record }?.undone)
    }

    /// 最近改动 keeps 100 records: once this one has gone, 恢复 still brings back the file and the directive.
    func testRecentlyDeletedRestoresAfterItsRecordIsGone() async throws {
        let (store, root) = try await fixture(documents: [document("2026-10-19")])
        let entry = try XCTUnwrap(store.L?.documents.first)
        let deleted = await store.deleteDocument(entry, file: true, summary: "test")
        XCTAssertTrue(deleted)
        await store.waitForSavedSync()
        await store.finishAttachmentDeletions()
        var items = store.deletedAttachments()
        items[0].record = nil
        try RecoveryFiles.save(items, kind: "deleted-attachments", ledger: store.cfg.id)
        let recovered = await store.recoverDeletedAttachment(items[0].id)
        XCTAssertTrue(recovered)
        await store.waitForSavedSync()
        await store.refresh()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        let restored = try XCTUnwrap(store.L?.documents.first)
        XCTAssertEqual(documentRepoPath(restored), path)
        XCTAssertEqual(restored.date, "2026-10-19")
        XCTAssertEqual(restored.account, "Assets:Bank:DemoBank")
        XCTAssertTrue(store.deletedAttachments().isEmpty)
    }

    func testAFileAnotherRecordStillUsesIsKept() async throws {
        let (store, root) = try await fixture(documents: [document("2026-10-19"), document("2026-10-20")])
        let entry = try XCTUnwrap(store.L?.documents.first)
        let deleted = await store.deleteDocument(entry, file: true, summary: "test")
        XCTAssertTrue(deleted)
        await store.waitForSavedSync()
        await store.finishAttachmentDeletions()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        XCTAssertEqual(store.L?.documents.count, 1)
        XCTAssertTrue(store.deletedAttachments().isEmpty)
    }

    func testRemovingOnlyTheRecordLeavesTheFile() async throws {
        let (store, root) = try await fixture(documents: [document("2026-10-19")])
        let entry = try XCTUnwrap(store.L?.documents.first)
        let deleted = await store.deleteDocument(entry, file: false, summary: "test")
        XCTAssertTrue(deleted)
        await store.waitForSavedSync()
        await store.finishAttachmentDeletions()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        XCTAssertTrue(store.L?.documents.isEmpty ?? false)
        XCTAssertTrue(store.deletedAttachments().isEmpty)
    }
}
