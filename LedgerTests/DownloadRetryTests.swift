import XCTest
@testable import Ledger
import LedgerKit

/// A file whose download fails for a moment (a dropped connection, a busy host) is tried again, instead of failing
/// the whole sync or 清除缓存并重新下载; one that can't pass that way (credentials) fails at once. Fictional data only.
final class DownloadRetryTests: XCTestCase {
    func testAFileDroppedOnceIsReadAgain() async throws {
        let backend = FlakyBackend(failing: ["sha2": [URLError(.networkConnectionLost)]])
        var texts: [String: String] = [:]
        try await backend.readEach([("a.bean", "sha1"), ("b.bean", "sha2")]) { sha, text in texts[sha] = text }
        XCTAssertEqual(texts, ["sha1": "; a.bean", "sha2": "; b.bean"])
        let reads = await backend.log.reads("sha2")
        XCTAssertEqual(reads, 2)
    }

    func testABusyHostIsTriedThreeTimesInAll() async throws {
        let busy = GitHubError(status: 503, message: "busy")
        let backend = FlakyBackend(failing: ["sha1": [busy, busy, busy]])
        do {
            try await backend.readEach([("a.bean", "sha1")]) { _, _ in }
            XCTFail("read although the host stayed busy")
        } catch {}
        let reads = await backend.log.reads("sha1")
        XCTAssertEqual(reads, 3)
    }

    func testCredentialsThatDontWorkAreNotTriedAgain() async throws {
        let backend = FlakyBackend(failing: ["sha1": [GitHubError(status: 401, message: "")]])
        do {
            try await backend.readEach([("a.bean", "sha1")]) { _, _ in }
            XCTFail("read with credentials that don't work")
        } catch {}
        let reads = await backend.log.reads("sha1")
        XCTAssertEqual(reads, 1)
    }

    /// 清除缓存并重新下载 reads through the same retries
    @MainActor
    func testDownloadingEverythingAgainSurvivesADroppedFile() async throws {
        let store = Store()
        var config = RepoConfig()
        config.id = "retry-test-" + UUID().uuidString
        config.kind = .local
        config.folderName = config.id
        let root = FolderBackend.localRoot(config.folderName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "2026-01-01 open Assets:Cash CNY\n".write(to: root.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        store.cfg = config
        store.pending = []
        store.mainFile = "main.bean"
        await store.refresh()
        let version = "retry-main-" + UUID().uuidString
        addTeardownBlock { @MainActor in
            BlobCache.remove(version)
            try? FileManager.default.removeItem(at: root)
        }

        let source = FlakyBackend(failing: [version: [URLError(.timedOut)]], tree: ["main.bean": version])
        let done = await store.resetCache(from: source)
        XCTAssertTrue(done)
        let reads = await source.log.reads(version)
        XCTAssertEqual(reads, 2)
    }
}

private actor ReadLog {
    private var failing: [String: [Error]]
    private var count: [String: Int] = [:]
    init(_ failing: [String: [Error]]) { self.failing = failing }
    /// the next failure planned for this version, if any
    func read(_ version: String) -> Error? {
        count[version, default: 0] += 1
        guard var errors = failing[version], !errors.isEmpty else { return nil }
        let e = errors.removeFirst()
        failing[version] = errors
        return e
    }
    func reads(_ version: String) -> Int { count[version] ?? 0 }
}

/// a host whose reads fail as planned, then succeed
private final class FlakyBackend: LedgerBackend {
    let log: ReadLog
    let tree: [String: String]
    init(failing: [String: [Error]], tree: [String: String] = [:]) {
        log = ReadLog(failing)
        self.tree = tree
    }
    func read(_ path: String, version: String) async throws -> String {
        if let e = await log.read(version) { throw e }
        return path == "main.bean" ? "2026-01-01 open Assets:Cash CNY\n" : "; " + path
    }
    func fetchTree() async throws -> RepoTree { RepoTree(sha: "retry", files: tree) }
    func write(_ path: String, text: String, version: String?, message: String) async throws -> String { throw URLError(.unsupportedURL) }
    func delete(_ path: String, version: String, message: String) async throws { throw URLError(.unsupportedURL) }
    func readData(_ path: String) async throws -> Data { throw URLError(.unsupportedURL) }
    func writeData(_ path: String, data: Data, message: String) async throws { throw URLError(.unsupportedURL) }
    func check() async -> GitHub.CI? { nil }
    func webURL(_ file: String, line: Int?) -> URL? { nil }
    var repoURL: URL? { nil }
}
