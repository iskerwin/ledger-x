import XCTest
import SwiftUI
@testable import Ledger
import LedgerKit

@MainActor
final class AttachmentUploadTests: XCTestCase {
    private let source = """
    2026-01-01 open Assets:Bank:DemoBank CNY
    2026-01-01 open Expenses:Food CNY
    2026-01-01 open Equity:Opening CNY
    2026-01-01 * "Opening"
      Assets:Bank:DemoBank 100 CNY
      Equity:Opening -100 CNY
    2026-10-19 * "Example cafe"
      Expenses:Food 12 CNY
      Assets:Bank:DemoBank -12 CNY
    """
    private let path = "documents/demobank/custom_receipt.jpg"

    private func fixture() async throws -> (Store, Entry) {
        let store = Store()
        var config = RepoConfig()
        config.id = "attachment-test-" + UUID().uuidString
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
            await store.waitForSavedSync()
            try? RecoveryFiles.remove(kind: "attachments", ledger: config.id)
            try? FileManager.default.removeItem(at: root)
        }
        return (store, try XCTUnwrap(store.L?.txns.last))
    }

    /// The recovery state on disk as a crash would leave it, read afresh as after a relaunch.
    private func persist(_ jobs: [AttachmentUpload], _ store: Store) throws {
        for job in jobs { try RecoveryFiles.saveData(job.data, kind: Store.attachmentDataKind(job.id), ledger: store.cfg.id) }
        try RecoveryFiles.save(jobs, kind: "attachments", ledger: store.cfg.id)
        store.attachmentJobCache = nil
    }

    private func prepare(_ store: Store, _ entry: Entry) throws -> AttachmentUpload {
        try store.prepareAttachment(Data([1, 2, 3]), to: entry, ledgerID: store.cfg.id, path: path, account: "Assets:Bank:DemoBank")
    }

    /// The saved job list must not carry the photo: views read the list on every redraw.
    func testJobListKeepsThePhotoInAFileOfItsOwn() async throws {
        let (store, entry) = try await fixture()
        let photo = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let job = try store.prepareAttachment(photo, to: entry, ledgerID: store.cfg.id, path: path, account: "Assets:Bank:DemoBank")
        defer { try? RecoveryFiles.removeData(kind: Store.attachmentDataKind(job.id), ledger: store.cfg.id) }
        struct Saved: Decodable { let id: UUID; let data: Data? }
        let saved = try XCTUnwrap(RecoveryFiles.load([Saved].self, kind: "attachments", ledger: store.cfg.id))
        XCTAssertEqual(saved.map(\.id), [job.id])
        XCTAssertNil(saved.first?.data)
        XCTAssertEqual(RecoveryFiles.loadData(kind: Store.attachmentDataKind(job.id), ledger: store.cfg.id), photo)
        // read afresh, as after a relaunch: the photo comes back with its job
        store.attachmentJobCache = nil
        XCTAssertEqual(store.attachmentJobs().first?.data, photo)
    }

    /// A list saved by an earlier version, photo inline, still recovers that photo and is moved to the new layout.
    func testJobListSavedWithThePhotoInlineIsMovedOut() async throws {
        let (store, entry) = try await fixture()
        let job = try prepare(store, entry)
        defer { try? RecoveryFiles.removeData(kind: Store.attachmentDataKind(job.id), ledger: store.cfg.id) }
        struct Legacy: Encodable {
            let id: UUID, ledgerID: String, source: String, sourceStartLine: Int?, sourceFileHash: String?
            let file: String, date: String, account: String, path: String, link: String, data: Data, uploaded: Bool
        }
        let legacy = Legacy(id: job.id, ledgerID: job.ledgerID, source: job.source, sourceStartLine: job.sourceStartLine,
                            sourceFileHash: job.sourceFileHash, file: job.file, date: job.date, account: job.account,
                            path: job.path, link: job.link, data: Data([4, 5, 6]), uploaded: false)
        try RecoveryFiles.removeData(kind: Store.attachmentDataKind(job.id), ledger: store.cfg.id)
        try RecoveryFiles.save([legacy], kind: "attachments", ledger: store.cfg.id)
        store.attachmentJobCache = nil
        XCTAssertEqual(store.attachmentJobs().first?.data, Data([4, 5, 6]))
        XCTAssertEqual(RecoveryFiles.loadData(kind: Store.attachmentDataKind(job.id), ledger: store.cfg.id), Data([4, 5, 6]))
        struct Saved: Decodable { let data: Data? }
        XCTAssertNil(try XCTUnwrap(RecoveryFiles.load([Saved].self, kind: "attachments", ledger: store.cfg.id)).first?.data)
    }

    func testAccountDocumentTreeRefreshDoesNotReportItsOwnSaveAsDuplicate() async throws {
        let (store, _) = try await fixture()
        func issue(isSaving: Bool) -> String? {
            documentLocationIssue(folder: "demobank", stem: "custom_receipt", ext: "jpg",
                                  existing: Set(store.tree?.files.keys.map { $0 } ?? []), isSaving: isSaving)
        }
        XCTAssertNil(issue(isSaving: false))
        let saved = try await store.addAccountDocument(account: "Assets:Bank:DemoBank", date: "2026-10-19",
                                                       folder: "demobank", fileName: "custom_receipt.jpg", data: Data([1, 2, 3]))
        XCTAssertTrue(saved)
        await store.waitForSavedSync()
        await store.refresh()
        XCTAssertNotNil(store.tree?.files[path])
        XCTAssertEqual(store.L?.documents.filter { documentRepoPath($0) == path }.count, 1)
        // A successful save stays busy until dismissal; reopening must still detect a real collision.
        XCTAssertNil(issue(isSaving: true))
        XCTAssertNotNil(issue(isSaving: false))
        let duplicate = try await store.addAccountDocument(account: "Assets:Bank:DemoBank", date: "2026-10-19",
                                                           folder: "demobank", fileName: "custom_receipt.jpg", data: Data([9]))
        XCTAssertFalse(duplicate)
        let bytes = try await store.backend.readData(path)
        XCTAssertEqual(bytes, Data([1, 2, 3]))
    }

    func testCompletedAttachmentCleanupOnlyReportsCollisionWhenEditing() async throws {
        let (store, entry) = try await fixture()
        let job = try prepare(store, entry)
        func issue(isSaving: Bool) -> String? {
            documentLocationIssue(folder: "demobank", stem: "custom_receipt", ext: "jpg",
                                  existing: store.attachmentTakenPaths(excluding: job.id), isSaving: isSaving)
        }
        XCTAssertNil(issue(isSaving: false))
        try await store.uploadAttachment(job)
        await store.waitForSavedSync()
        await store.refresh()
        XCTAssertTrue(store.attachmentJobs().isEmpty)
        XCTAssertTrue(store.attachmentTakenPaths(excluding: job.id).contains(path))
        // Cleanup removes the job identity before the confirmation sheet has finished closing.
        XCTAssertNil(issue(isSaving: true))
        // If the form becomes editable after a failure, collisions must be visible again.
        XCTAssertNotNil(issue(isSaving: false))
        XCTAssertNotNil(documentLocationIssue(folder: "demobank", stem: "", ext: "jpg", existing: []))
    }

    func testSheetStartsWithAvailableFullNameAndKeepsManualNameAcrossTreeRefresh() async throws {
        let (store, entry) = try await fixture()
        defer { try? RecoveryFiles.remove(kind: "attachments", ledger: store.cfg.id) }
        // a transaction attachment defaults to receipts/, apart from the bank's statements
        let base = "documents/receipts/receipts_20261019"
        for suffix in [".jpg", "_1.jpg", "_2.pdf"] {
            try await store.backend.writeData(base + suffix, data: Data([1]), message: "test fixture")
        }
        await store.refresh()
        XCTAssertTrue(store.attachmentTakenPaths().contains(base + ".jpg"))
        XCTAssertTrue(store.attachmentTakenPaths().contains(base + "_1.jpg"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: AttachmentPathSheet(
            entry: entry, data: Data([1]), ext: "jpg", ledgerID: store.cfg.id,
            existingPaths: store.attachmentTakenPaths()).environment(store))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        // Fulfilled by the UI lifecycle, without a fixed sleep.
        let probe = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.textField(in: controller.view) != nil
        }, object: nil)
        await fulfillment(of: [probe], timeout: 10)
        let field = try XCTUnwrap(textField(in: controller.view))
        XCTAssertEqual(field.text, "receipts_20261019_2")
        field.becomeFirstResponder()
        field.selectAll(nil)
        field.insertText("my_receipt")
        field.resignFirstResponder()
        try await store.backend.writeData(base + "_2.jpg", data: Data([2]), message: "test refresh")
        await store.refresh()
        let retained = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.textField(in: controller.view)?.text == "my_receipt"
        }, object: nil)
        await fulfillment(of: [retained], timeout: 5)
        // Force a further render before the assertion, so a deferred default refresh cannot hide it.
        controller.view.layoutIfNeeded()
        XCTAssertEqual(field.text, "my_receipt")
    }

    private func textField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        return view.subviews.lazy.compactMap { self.textField(in: $0) }.first
    }

    func testOwnRecoveryIsExcludedButOtherJobsAndExtensionsAreStillCompared() async throws {
        let (store, entry) = try await fixture()
        defer { try? RecoveryFiles.remove(kind: "attachments", ledger: store.cfg.id) }
        let own = try prepare(store, entry)
        XCTAssertTrue(store.attachmentTakenPaths().contains(path))
        XCTAssertFalse(store.attachmentTakenPaths(excluding: own.id).contains(path))
        XCTAssertThrowsError(try prepare(store, entry))
        let other = "documents/demobank/custom_receipt.pdf"
        _ = try store.prepareAttachment(Data([4]), to: entry, ledgerID: store.cfg.id, path: other, account: own.account)
        XCTAssertTrue(store.attachmentTakenPaths(excluding: own.id).contains(other))
        XCTAssertTrue(store.attachmentTakenPaths(excluding: UUID()).contains(path))
    }

    func testUploadFailureReturnsActualErrorAndRetryUsesConfirmedName() async throws {
        let (store, entry) = try await fixture()
        defer { try? RecoveryFiles.remove(kind: "attachments", ledger: store.cfg.id) }
        let job = try prepare(store, entry)
        let backend = AttachmentTestBackend()
        backend.failure = GitHubError(status: 403, message: "example upload denied")
        do {
            try await store.uploadAttachment(job, destination: backend)
            XCTFail("Expected upload failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("example upload denied"))
        }
        XCTAssertFalse(store.attachmentUploading)
        XCTAssertEqual(store.attachmentJobs().first?.path, path)
        XCTAssertFalse(store.attachmentJobs().first!.uploaded)
        XCTAssertTrue(store.pending.isEmpty)
        backend.failure = nil
        try await store.uploadAttachment(job, destination: backend)
        XCTAssertEqual(backend.paths, [path, path])
        XCTAssertTrue(store.attachmentJobs().isEmpty)
        XCTAssertTrue(store.L?.documents.contains { documentRepoPath($0) == path } == true)
    }

    func testCancelDuringWriteRetainsUploadedCopyWithoutAssociatingAndRetryDoesNotUploadAgain() async throws {
        let (store, entry) = try await fixture()
        defer { try? RecoveryFiles.remove(kind: "attachments", ledger: store.cfg.id) }
        let job = try prepare(store, entry)
        let backend = AttachmentTestBackend()
        let gate = AttachmentWriteGate()
        backend.gate = gate
        let task = Task { try await store.uploadAttachment(job, destination: backend) }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertFalse(store.attachmentUploading)
        let retained = try XCTUnwrap(store.attachmentJobs().first)
        XCTAssertTrue(retained.uploaded)
        try await store.backend.writeData(path, data: Data([1, 2, 3]), message: "test uploaded file")
        await store.refresh()
        XCTAssertFalse(store.attachmentTakenPaths(excluding: job.id).contains(path))
        backend.gate = nil
        try await store.uploadAttachment(retained, destination: backend)
        XCTAssertEqual(backend.paths, [path])
        XCTAssertTrue(store.attachmentJobs().isEmpty)
    }

    func testCancelledBeforeStartNeverWritesOrQueues() async throws {
        let (store, entry) = try await fixture()
        defer { try? RecoveryFiles.remove(kind: "attachments", ledger: store.cfg.id) }
        let job = try prepare(store, entry)
        let backend = AttachmentTestBackend()
        let task = Task { try await store.uploadAttachment(job, destination: backend) }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(backend.paths.isEmpty)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(store.attachmentJobs().first?.id, job.id)
    }

    func testIdenticalTransactionsKeepOriginalLocationAndLegacyAmbiguityDoesNotGuess() async throws {
        let (store, entry) = try await fixture()
        // One identical transaction starts at line zero, where parsing job.source alone would point.
        let root = FolderBackend.localRoot(store.cfg.folderName)
        try (entry.src + "\n\n" + source).write(to: root.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        await store.refresh()
        let copies = try XCTUnwrap(store.L).txns.filter { $0.date == entry.date }
        XCTAssertEqual(copies.count, 2)
        let target = try XCTUnwrap(copies.last)
        let job = try prepare(store, target)
        XCTAssertEqual(job.sourceStartLine, target.startLine)
        XCTAssertNotNil(job.sourceFileHash)
        let backend = AttachmentTestBackend()
        let changed = entry.src + "\n\n" + source.replacingOccurrences(of: "Example cafe", with: "Changed cafe")
        try changed.write(to: root.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        await store.refresh()
        do { try await store.uploadAttachment(job, destination: backend); XCTFail("Expected changed ambiguous source rejection") } catch { }
        XCTAssertTrue(backend.paths.isEmpty)
        XCTAssertTrue(store.pending.isEmpty)
        try (entry.src + "\n\n" + source).write(to: root.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        await store.refresh()
        var legacy = job
        legacy.sourceStartLine = nil
        legacy.sourceFileHash = nil
        try persist([legacy], store)
        do { try await store.uploadAttachment(legacy, destination: backend); XCTFail("Expected ambiguous legacy transaction rejection") } catch { }
        XCTAssertTrue(backend.paths.isEmpty)
        XCTAssertTrue(store.pending.isEmpty)
        try persist([job], store)
        try await store.uploadAttachment(job, destination: backend)
        let saved = try XCTUnwrap(store.L).txns.filter { $0.date == entry.date }
        XCTAssertFalse(try XCTUnwrap(saved.first).links.contains(job.link))
        XCTAssertTrue(try XCTUnwrap(saved.last).links.contains(job.link))
        var completed = job
        completed.uploaded = true
        try persist([completed], store)
        try await store.uploadAttachment(job, destination: backend)
        XCTAssertTrue(store.attachmentJobs().isEmpty)
        XCTAssertEqual(backend.paths, [path])
    }

    func testFolderAttachmentPublicationNeverOverwritesAnExistingFile() async throws {
        let (store, _) = try await fixture()
        try await store.backend.writeData(path, data: Data([7]), message: "test existing file")
        do {
            try await store.backend.writeData(path, data: Data([8]), message: "test conflicting file")
            XCTFail("Expected create-only publication")
        } catch { }
        let retained = try await store.backend.readData(path)
        XCTAssertEqual(retained, Data([7]))
        await store.refresh()
        XCTAssertTrue(store.attachmentTakenPaths().contains(path))
    }

    func testLostResponseRetryVerifiesBytesInsteadOfUploadingAgain() async throws {
        let (store, entry) = try await fixture()
        let job = try prepare(store, entry)
        let backend = AttachmentTestBackend()
        backend.writesBeforeFailure = true
        backend.failure = CancellationError()
        do { try await store.uploadAttachment(job, destination: backend); XCTFail("Expected lost response") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(store.attachmentJobs().first?.uploadStarted == true)
        XCTAssertFalse(store.attachmentJobs().first!.uploaded)
        backend.failure = nil
        try await store.backend.writeData(path, data: job.data, message: "test response lost after write")
        await store.refresh()
        XCTAssertTrue(store.attachmentTakenPaths().contains(path))
        XCTAssertFalse(store.attachmentTakenPaths(excluding: job.id).contains(path))
        try await store.uploadAttachment(job, destination: backend)
        XCTAssertEqual(backend.paths, [path])
        XCTAssertEqual(store.L?.documents.filter { documentRepoPath($0) == path }.count, 1)
    }

    func testUncertainWriteNeverOverwritesDifferentBytesOrUnreadableFile() async throws {
        let (store, entry) = try await fixture()
        let job = try prepare(store, entry)
        let backend = AttachmentTestBackend()
        backend.failure = GitHubError(status: 503, message: "test lost response")
        do { try await store.uploadAttachment(job, destination: backend); XCTFail("Expected failure") } catch { }
        backend.failure = nil
        backend.remote = Data([9])
        do { try await store.uploadAttachment(job, destination: backend); XCTFail("Expected collision") } catch { }
        backend.readFailure = GitHubError(status: 403, message: "test cannot verify")
        do { try await store.uploadAttachment(job, destination: backend); XCTFail("Expected verification failure") } catch { }
        XCTAssertEqual(backend.paths, [path])
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(store.attachmentJobs().first?.id, job.id)
    }

    func testUploadedRecoveryVerifiesRemoteContentBeforeAssociation() async throws {
        let (store, entry) = try await fixture()
        var job = try prepare(store, entry)
        job.uploaded = true
        try persist([job], store)
        let backend = AttachmentTestBackend()
        backend.remote = Data([9])
        do { try await store.uploadAttachment(job, destination: backend); XCTFail("Expected changed file rejection") } catch { }
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(backend.paths.isEmpty)
        XCTAssertEqual(store.attachmentJobs().first?.id, job.id)
        backend.remote = job.data
        try await store.uploadAttachment(job, destination: backend)
        XCTAssertTrue(backend.paths.isEmpty)
        XCTAssertTrue(store.attachmentJobs().isEmpty)
    }

    func testDiscardedTaskCannotBeResurrectedByStaleRetry() async throws {
        let (store, entry) = try await fixture()
        let job = try prepare(store, entry)
        store.discardAttachmentJob(job)
        let backend = AttachmentTestBackend()
        do { try await store.uploadAttachment(job, destination: backend); XCTFail("Expected stale task rejection") } catch { }
        XCTAssertTrue(backend.paths.isEmpty)
        XCTAssertTrue(store.attachmentJobs().isEmpty)
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testConcurrentRetryAndLedgerChangeAreBlockedUntilCancelledWriteFinishes() async throws {
        let (store, entry) = try await fixture()
        let job = try prepare(store, entry)
        let backend = AttachmentTestBackend()
        let gate = AttachmentWriteGate()
        backend.gate = gate
        let task = Task { try await store.uploadAttachment(job, destination: backend) }
        await gate.waitUntilStarted()
        task.cancel()
        do { try await store.uploadAttachment(job, destination: backend); XCTFail("Expected busy rejection") } catch { }
        var other = store.cfg
        other.id = "attachment-test-" + UUID().uuidString
        await store.saveConfig(other)
        XCTAssertEqual(store.cfg.id, job.ledgerID)
        XCTAssertTrue(store.attachmentUploading)
        await gate.release()
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(backend.paths, [path])
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertTrue(store.attachmentJobs().first!.uploaded)
        // An old-ledger task must never reach another ledger's backend or recovery file.
        let originalConfig = store.cfg
        store.cfg = other
        do { try await store.uploadAttachment(job, destination: backend); XCTFail("Expected wrong ledger rejection") } catch { }
        XCTAssertTrue(store.attachmentJobs().isEmpty)
        store.cfg = originalConfig
        XCTAssertEqual(store.attachmentJobs().first?.id, job.id)
    }

    func testCompletedAssociationRecoveryDoesNotDuplicateAndDifferentLinkDoesNotDiscard() async throws {
        let (store, entry) = try await fixture()
        let job = try prepare(store, entry)
        let backend = AttachmentTestBackend()
        try await store.uploadAttachment(job, destination: backend)
        await store.waitForSavedSync()
        // Simulate a crash after the durable association but before recovery cleanup.
        var completed = job
        completed.uploaded = true
        try persist([completed], store)
        XCTAssertTrue(store.attachmentTakenPaths().contains(path))
        XCTAssertFalse(store.attachmentTakenPaths(excluding: job.id).contains(path))
        try await store.uploadAttachment(job, destination: backend)
        XCTAssertTrue(store.attachmentJobs().isEmpty)
        XCTAssertEqual(backend.paths, [path])
        XCTAssertEqual(store.L?.documents.filter { documentRepoPath($0) == path }.count, 1)
        XCTAssertThrowsError(try prepare(store, entry))
        var unrelated = job
        unrelated.id = UUID()
        unrelated.link = "doc-unrelated-task"
        try persist([unrelated], store)
        do { try await store.uploadAttachment(unrelated, destination: backend); XCTFail("Expected mismatched association") } catch { }
        XCTAssertEqual(store.attachmentJobs().first?.id, unrelated.id)
        XCTAssertEqual(backend.paths, [path])
    }

    func testCancellationAfterQueueKeepsSavedAssociation() async throws {
        let (store, _) = try await fixture()
        var task: Task<Bool, Never>!
        var op = Op(kind: .insert, path: "main.bean")
        op.text = "2026-10-19 document Assets:Bank:DemoBank \"documents/demobank/queued.jpg\" ^doc-queued"
        task = Task { await store.commit([op], checked: true, cancellable: true, onQueued: { task.cancel() }) }
        let saved = await task.value
        XCTAssertTrue(saved)
        XCTAssertTrue(store.L?.documents.contains { $0.links.contains("doc-queued") } == true)
        XCTAssertFalse(store.committing)
    }

    func testCancelledCommitDoesNotQueueAssociation() async throws {
        let (store, _) = try await fixture()
        let task = Task { await store.commit([Op(kind: .insert, path: "main.bean")], checked: true, cancellable: true) }
        task.cancel()
        let saved = await task.value
        XCTAssertFalse(saved)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertFalse(store.committing)
    }
}

/// A manually released request models a backend which completes its write despite cancellation.
private actor AttachmentWriteGate {
    private var started = false
    private var ready: CheckedContinuation<Void, Never>?
    private var finish: CheckedContinuation<Void, Never>?
    func run() async {
        await withCheckedContinuation { continuation in
            finish = continuation
            started = true
            ready?.resume()
            ready = nil
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { ready = $0 }
    }
    func release() { finish?.resume(); finish = nil }
}

private final class AttachmentTestBackend: LedgerBackend {
    var paths: [String] = []
    var failure: Error?
    var gate: AttachmentWriteGate?
    var remote: Data?
    var readFailure: Error?
    var writesBeforeFailure = false
    func writeData(_ path: String, data: Data, message: String) async throws {
        paths.append(path)
        if let gate { await gate.run() }
        if writesBeforeFailure { remote = data }
        if let failure { throw failure }
        remote = data
    }
    func fetchTree() async throws -> RepoTree { throw unexpected() }
    func read(_ path: String, version: String) async throws -> String { throw unexpected() }
    func write(_ path: String, text: String, version: String?, message: String) async throws -> String { throw unexpected() }
    func delete(_ path: String, version: String, message: String) async throws { throw unexpected() }
    func readData(_ path: String) async throws -> Data {
        if let readFailure { throw readFailure }
        guard let remote else { throw GitHubError(status: 404, message: "test missing attachment") }
        return remote
    }
    func check() async -> GitHub.CI? { nil }
    func webURL(_ file: String, line: Int?) -> URL? { nil }
    var repoURL: URL? { nil }
    private func unexpected() -> Error { GitHubError(status: 0, message: "Unexpected test backend request") }
}
