import XCTest
@testable import Ledger
import LedgerKit

/// 清除缓存并重新下载: offline, or with one file failing, the copy on the phone stays readable; the other
/// ledgers' cached files are never thrown away with this one's.
@MainActor
final class CacheResetTests: XCTestCase {
    private let source = """
    2026-01-01 open Assets:Cash CNY
    2026-01-01 open Expenses:Food CNY

    2026-10-28 * "Reset cafe" "Coffee"
      Expenses:Food                                        9.90 CNY
      Assets:Cash                                         -9.90 CNY

    """

    private func fixture() async throws -> Store {
        let store = Store()
        var config = RepoConfig()
        config.id = "reset-test-" + UUID().uuidString
        config.kind = .local
        config.folderName = config.id
        let root = FolderBackend.localRoot(config.folderName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try source.write(to: root.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        store.cfg = config
        store.mainFile = "main.bean"
        await store.refresh()
        addTeardownBlock { @MainActor in try? FileManager.default.removeItem(at: root) }
        return store
    }

    func testOfflineOrAFailedFileLeavesTheCopyOnThePhone() async throws {
        let store = try await fixture()
        let tree = try XCTUnwrap(store.tree)
        let sha = try XCTUnwrap(tree.files["main.bean"])
        XCTAssertNotNil(BlobCache.get(sha))
        for backend in [ResetTestBackend(tree: nil), ResetTestBackend(tree: RepoTree(sha: "new", files: ["main.bean": String(repeating: "b", count: 40)]))] {
            let ok = await store.resetCache(from: backend)
            XCTAssertFalse(ok)
            XCTAssertEqual(store.tree, tree, "the tree on the phone is kept")
            XCTAssertEqual(BlobCache.get(sha), source, "the cached file is kept")
            XCTAssertNotNil(store.L)
        }
    }

    func testAPhoneThatCannotStoreTheNewCopyKeepsTheOldOne() async throws {
        let store = try await fixture()
        let sha = try XCTUnwrap(store.tree?.files["main.bean"])
        let writeFile = BlobCache.writeFile
        BlobCache.writeFile = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        defer { BlobCache.writeFile = writeFile }
        let ok = await store.resetCache()
        XCTAssertFalse(ok, "reported, not shown as done")
        XCTAssertEqual(BlobCache.get(sha), source, "the cached file is kept")
        XCTAssertNotNil(store.L)
    }

    func testAResetKeepsFilesThisLedgerDoesNotUse() async throws {
        let store = try await fixture()
        let other = String(repeating: "a", count: 40)
        BlobCache.set(other, "; another ledger's file")
        addTeardownBlock { BlobCache.remove(other) }
        let ok = await store.resetCache()
        XCTAssertTrue(ok)
        XCTAssertEqual(BlobCache.get(other), "; another ledger's file")
        XCTAssertEqual(store.tree?.files["main.bean"].flatMap(BlobCache.get), source)
    }
}

/// fetchTree answers with `tree` (nil: offline); every read fails
private final class ResetTestBackend: LedgerBackend {
    let tree: RepoTree?
    init(tree: RepoTree?) { self.tree = tree }
    func fetchTree() async throws -> RepoTree {
        guard let tree else { throw URLError(.notConnectedToInternet) }
        return tree
    }
    func read(_ path: String, version: String) async throws -> String { throw URLError(.timedOut) }
    func write(_ path: String, text: String, version: String?, message: String) async throws -> String { throw URLError(.notConnectedToInternet) }
    func delete(_ path: String, version: String, message: String) async throws { throw URLError(.notConnectedToInternet) }
    func readData(_ path: String) async throws -> Data { throw URLError(.notConnectedToInternet) }
    func writeData(_ path: String, data: Data, message: String) async throws { throw URLError(.notConnectedToInternet) }
    func check() async -> GitHub.CI? { nil }
    func webURL(_ file: String, line: Int?) -> URL? { nil }
    var repoURL: URL? { nil }
}
