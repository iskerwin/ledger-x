#if os(macOS)
import XCTest
@testable import LedgerKit

final class FolderWatcherTests: XCTestCase {
    func testReportsAFileChangedInASubfolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journals = folder.appendingPathComponent("journals")
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let changed = expectation(description: "change reported")
        changed.assertForOverFulfill = false
        let watcher = FolderWatcher(folder) { changed.fulfill() }
        try "2026-10-16 open Assets:Bank\n".write(to: journals.appendingPathComponent("2026.bean"), atomically: true, encoding: .utf8)
        wait(for: [changed], timeout: 30)
        withExtendedLifetime(watcher) {}
    }

    func testGitBookkeepingIsNotAChange() {
        XCTAssertFalse(isWatchedChange("/books/.git/index"))
        XCTAssertFalse(isWatchedChange("/books/.git/refs/heads/main"))
        XCTAssertFalse(isWatchedChange("/books/.git"))
        XCTAssertTrue(isWatchedChange("/books/main.bean"))
        XCTAssertTrue(isWatchedChange("/books/journals/2026.bean"))
        XCTAssertTrue(isWatchedChange("/books/.gitignore"))
    }
}
#endif
