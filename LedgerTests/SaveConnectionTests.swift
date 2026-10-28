import XCTest
@testable import Ledger
import LedgerKit

/// Saving the connection while an entry or attachment is still being saved changes nothing and says so, so the
/// settings and connection pages don't go on to say 已保存.
@MainActor
final class SaveConnectionTests: XCTestCase {
    func testSavingTheConnectionDuringASaveChangesNothing() async {
        let store = Store()
        var config = RepoConfig()
        config.id = "save-connection-" + UUID().uuidString
        config.kind = .local
        config.folderName = config.id
        store.cfg = config
        var edited = config
        edited.branch = "other"
        store.attachmentUploading = true
        let saved = await store.saveConfig(edited)
        XCTAssertFalse(saved)
        XCTAssertEqual(store.cfg.branch, config.branch)
        store.attachmentUploading = false
    }
}
