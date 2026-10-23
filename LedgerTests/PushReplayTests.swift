import XCTest
@testable import Ledger
import LedgerKit

/// The app killed after the host took a push but before the queue was saved: on the next push the same entry must
/// not be written a second time.
@MainActor
final class PushReplayTests: XCTestCase {
    private let source = """
    2026-01-01 open Assets:Cash CNY
    2026-01-01 open Expenses:Food CNY

    """
    private let coffee = """
    2026-10-02 * "Replay cafe" "Coffee"
      Expenses:Food                                        9.90 CNY
      Assets:Cash                                         -9.90 CNY
    """

    func testAPushThatLandedBeforeACrashIsNotWrittenAgain() async throws {
        let store = Store()
        var config = RepoConfig()
        config.id = "replay-test-" + UUID().uuidString
        config.kind = .local
        config.folderName = config.id
        let root = FolderBackend.localRoot(config.folderName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let main = root.appendingPathComponent("main.bean")
        try source.write(to: main, atomically: true, encoding: .utf8)
        store.cfg = config
        store.mainFile = "main.bean"
        await store.refresh()
        addTeardownBlock { @MainActor in
            try? RecoveryFiles.remove(kind: "inflight", ledger: config.id)
            try? FileManager.default.removeItem(at: root)
        }

        // as a crash leaves it: the queue still holds the entry, the host already has it, the push was written down
        var op = Op(kind: .insert, path: "main.bean")
        op.text = coffee
        op.date = "2026-10-02"
        let plan = planPush([op], bases: ["main.bean": source])
        try XCTUnwrap(plan.changes.first?.text).write(to: main, atomically: true, encoding: .utf8)
        try RecoveryFiles.save(InFlightPush(ids: plan.included, changes: plan.changes), kind: "inflight", ledger: config.id)
        store.pending = [op]
        store.savePending()

        try await store.pushPending()
        let text = try String(contentsOf: main, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "Replay cafe").count - 1, 1, text)
        XCTAssertTrue(store.pending.isEmpty)
    }
}
