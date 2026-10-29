import XCTest
@testable import Ledger
import LedgerKit

/// The first download of a ledger with many files reads a few at a time instead of all at once,
/// so the host's rate limit is not hit; every file still arrives.
final class FirstDownloadTests: XCTestCase {
    func testManyFilesAreReadAtMostFourAtATime() async throws {
        let backend = CountingBackend()
        let files = (1...20).map { ("books/\($0).bean", "sha\($0)") }
        var texts: [String: String] = [:]
        try await backend.readEach(files) { sha, text in texts[sha] = text }
        XCTAssertEqual(texts.count, 20)
        XCTAssertEqual(texts["sha7"], "; books/7.bean")
        let most = await backend.counter.most
        XCTAssertLessThanOrEqual(most, 4)
        XCTAssertGreaterThan(most, 1, "files are still read side by side")
    }
}

private actor ReadCounter {
    private var now = 0
    private(set) var most = 0
    func start() { now += 1; most = max(most, now) }
    func end() { now -= 1 }
}

/// every read takes a moment, like a request to the host
private final class CountingBackend: LedgerBackend {
    let counter = ReadCounter()
    func read(_ path: String, version: String) async throws -> String {
        await counter.start()
        try await Task.sleep(nanoseconds: 20_000_000)
        await counter.end()
        return "; " + path
    }
    func fetchTree() async throws -> RepoTree { throw URLError(.unsupportedURL) }
    func write(_ path: String, text: String, version: String?, message: String) async throws -> String { throw URLError(.unsupportedURL) }
    func delete(_ path: String, version: String, message: String) async throws { throw URLError(.unsupportedURL) }
    func readData(_ path: String) async throws -> Data { throw URLError(.unsupportedURL) }
    func writeData(_ path: String, data: Data, message: String) async throws { throw URLError(.unsupportedURL) }
    func check() async -> GitHub.CI? { nil }
    func webURL(_ file: String, line: Int?) -> URL? { nil }
    var repoURL: URL? { nil }
}
