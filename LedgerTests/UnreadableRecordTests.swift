import XCTest
import CryptoKit
@testable import Ledger
import LedgerKit

/// What the phone keeps per ledger (the sync queue, a push's note, attachment jobs, deleted attachments) is never
/// taken for empty when it can't be read back: written over, the changes in it were gone without a word. One that
/// can't be opened yet is left alone; one that doesn't read back is set aside, listed on the sync page, and
/// removed with the ledger. Fictional data only.
@MainActor
final class UnreadableRecordTests: XCTestCase {
    private let source = """
    2026-01-01 open Assets:Cash CNY
    2026-01-01 open Expenses:Food CNY

    """
    private let coffee = """
    2026-10-02 * "Paused cafe" "Coffee"
      Expenses:Food                                        9.90 CNY
      Assets:Cash                                         -9.90 CNY
    """

    /// where RecoveryFiles keeps a record (its own naming), to make it unreadable from outside
    private func file(_ kind: String, _ ledger: String, ext: String) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Recovery", isDirectory: true)
        let key = SHA256.hash(data: Data(ledger.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(kind + "-" + key + "." + ext)
    }

    private func op(_ text: String) -> Op {
        var op = Op(kind: .write, path: "main.bean")
        op.text = text
        return op
    }

    private func ledger(_ store: Store) async throws -> (RepoConfig, URL) {
        var config = RepoConfig()
        config.id = "unreadable-test-" + UUID().uuidString
        config.kind = .local
        config.folderName = config.id
        let root = FolderBackend.localRoot(config.folderName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try source.write(to: root.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        store.cfg = config
        store.pending = []
        store.mainFile = "main.bean"
        await store.refresh()
        addTeardownBlock { @MainActor in
            PendingQueue.remove(ledger: config.id)
            for kind in ["inflight", "attachments", "deleted-attachments"] { try? RecoveryFiles.remove(kind: kind, ledger: config.id) }
            for kind in UnreadableKind.allCases { RecoveryFiles.removeUnreadable(kind: kind, ledger: config.id) }
            try? FileManager.default.removeItem(at: root)
        }
        return (config, root)
    }

    func testAQueueThatCantBeOpenedYetIsNotWrittenOver() async throws {
        let store = Store()
        let (config, _) = try await ledger(store)
        try PendingQueue.save([op("; one")], ledger: config.id)
        let path = try file("pending", config.id, ext: "bin")
        // as before the phone is first unlocked: there, but not to be opened
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path) }

        guard case .unavailable = PendingQueue.read(ledger: config.id) else { return XCTFail("taken for something else") }
        // a change made meanwhile is not written over the queue
        store.pendingUnavailable = true
        store.pending = [op("; two")]
        store.savePending()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        XCTAssertEqual(try JSONDecoder().decode([Op].self, from: Data(contentsOf: path)).map(\.text), ["; one"])

        // once it opens, the queue comes back and the change made meanwhile goes after it
        store.savePending()
        XCTAssertEqual(store.pending.map(\.text), ["; one", "; two"])
        XCTAssertEqual(try JSONDecoder().decode([Op].self, from: Data(contentsOf: path)).map(\.text), ["; one", "; two"])
    }

    func testADamagedQueueIsSetAsideListedAndRemovedWithTheLedger() async throws {
        let store = Store()
        let (config, _) = try await ledger(store)
        try RecoveryFiles.saveData(Data("not a queue".utf8), kind: "pending", ledger: config.id)

        guard case .damaged = PendingQueue.read(ledger: config.id) else { return XCTFail("taken for something else") }
        let aside = try XCTUnwrap(RecoveryFiles.unreadable(ledger: config.id).first { $0.kind == .pending })
        XCTAssertEqual(try String(contentsOf: aside.url, encoding: .utf8), "not a queue", "kept as it was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try file("pending", config.id, ext: "bin").path))

        // forgetting the ledger removes it too
        let other = Store()
        other.removeLedger(config.id)
        XCTAssertTrue(RecoveryFiles.unreadable(ledger: config.id).isEmpty)
    }

    func testDamagedAttachmentJobsAreSetAsideNotWrittenOver() async throws {
        let store = Store()
        let (config, _) = try await ledger(store)
        try RecoveryFiles.save(["not": "jobs"], kind: "attachments", ledger: config.id)
        XCTAssertTrue(store.attachmentJobs().isEmpty)
        XCTAssertEqual(RecoveryFiles.load([String: String].self, kind: "attachments-unreadable", ledger: config.id), ["not": "jobs"])
    }

    func testDamagedDeletedAttachmentsAreSetAsideNotWrittenOver() async throws {
        let store = Store()
        let (config, _) = try await ledger(store)
        try RecoveryFiles.save(["not": "deleted"], kind: "deleted-attachments", ledger: config.id)
        XCTAssertTrue(store.deletedAttachments(ledger: config.id).isEmpty)
        XCTAssertEqual(RecoveryFiles.load([String: String].self, kind: "deleted-attachments-unreadable", ledger: config.id), ["not": "deleted"])
    }

    /// sent without its note, a push that had already landed would be written a second time: it waits until the
    /// note set aside is looked at and discarded
    func testADamagedPushNotePausesPushingUntilDiscarded() async throws {
        let store = Store()
        let (config, root) = try await ledger(store)
        let main = root.appendingPathComponent("main.bean")
        try RecoveryFiles.save(["not": "a push"], kind: "inflight", ledger: config.id)
        var entry = Op(kind: .insert, path: "main.bean")
        entry.text = coffee
        entry.date = "2026-10-02"
        store.pending = [entry]
        store.savePending()

        do {
            try await store.pushPending()
            XCTFail("pushed without its note")
        } catch {}
        XCTAssertEqual(store.pending.count, 1)
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), source)
        // a second try still waits
        do { try await store.pushPending(); XCTFail("pushed while set aside") } catch {}
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), source)

        store.discardUnreadable(.inflight)
        try await store.pushPending()
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(try String(contentsOf: main, encoding: .utf8).contains("Paused cafe"))
    }
}
