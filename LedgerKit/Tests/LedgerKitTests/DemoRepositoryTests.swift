import XCTest
@testable import LedgerKit

final class DemoRepositoryTests: XCTestCase {
    private let revision = String(repeating: "a", count: 40)
    private var sample: [String: Data] { [
        "main.bean": Data("""
        option "operating_currency" "CNY"
        include "accounts/accounts.bean"
        2026-10-16 * "Sample"
          Assets:Bank  -10.00 CNY
          Expenses:Food  10.00 CNY
        """.utf8),
        "accounts/accounts.bean": Data("2025-01-01 open Assets:Bank CNY\n2025-01-01 open Expenses:Food CNY\n".utf8),
        "ledger-x.json": Data("{}".utf8)
    ] }

    private func reader(_ files: [String: Data], truncated: Bool = false, mode: String = "100644") -> DemoRepository.Read {
        { url in
            if url.path.hasSuffix("/commits/main") {
                return try JSONSerialization.data(withJSONObject: ["sha": self.revision])
            }
            if url.host == "api.github.com" {
                XCTAssertTrue(url.path.contains(self.revision))
                let tree: [[String: Any]] = files.map { ["path": $0.key, "type": "blob", "mode": mode, "size": $0.value.count] }
                return try JSONSerialization.data(withJSONObject: ["truncated": truncated, "tree": tree])
            }
            XCTAssertEqual(url.host, "raw.githubusercontent.com")
            let prefix = "/iskerwin/ledger-demo/\(self.revision)/"
            XCTAssertTrue(url.path.hasPrefix(prefix), "Downloads must use the resolved commit, not main")
            guard let data = files[String(url.path.dropFirst(prefix.count))] else { throw URLError(.fileDoesNotExist) }
            return data
        }
    }

    func testPinnedSnapshotWithNestedFiles() async throws {
        let s = try await DemoRepository.snapshot(read: reader(sample))
        XCTAssertEqual(s.files, sample)
        XCTAssertEqual(s.commit, revision)
    }

    func testOfflineCacheAndSuccessfulReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let main = root.appendingPathComponent("main.bean")
        try Data("local edits".utf8).write(to: main)
        try await DemoRepository.install(at: root, read: { _ in XCTFail("Cached demos must work offline"); throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), "local edits")
        let installed = try await DemoRepository.install(at: root, reset: true, read: reader(sample))
        XCTAssertEqual(installed, revision)
        XCTAssertEqual(try Data(contentsOf: main), sample["main.bean"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("accounts/accounts.bean")), sample["accounts/accounts.bean"])
    }

    func testFailedResetKeepsAllOldFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let main = root.appendingPathComponent("main.bean")
        try Data("local edits".utf8).write(to: main)
        let read = reader(sample)
        do {
            try await DemoRepository.install(at: root, reset: true, read: { url in
                if url.host == "raw.githubusercontent.com" && url.path.hasSuffix("main.bean") { throw URLError(.timedOut) }
                return try await read(url)
            })
            XCTFail("A partial download must fail")
        } catch {}
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), "local edits")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["main.bean"])
    }

    func testRejectsUnsafeAndIncompleteSnapshots() async throws {
        var missing = sample; missing.removeValue(forKey: "accounts/accounts.bean")
        var unsafe = sample; unsafe["../outside.bean"] = Data()
        var invalid = sample; invalid["main.bean"] = Data("include \"missing.bean\"".utf8)
        for read in [reader(sample, truncated: true), reader(sample, mode: "120000"), reader(missing), reader(unsafe), reader(invalid)] {
            do { _ = try await DemoRepository.snapshot(read: read); XCTFail("Invalid snapshots must fail") }
            catch {}
        }
    }

    /// the mirror serves the same commit when GitHub can't be reached
    func testFallsBackToMirror() async throws {
        let mirror = URL(string: "https://mirror.example")!
        let files = sample
        let read: DemoRepository.Read = { url in
            guard url.host == "mirror.example" else { throw URLError(.cannotFindHost) }
            if url.path == "/demo/commit" { return try JSONSerialization.data(withJSONObject: ["sha": self.revision]) }
            if url.path == "/demo/tree/\(self.revision)" {
                let tree: [[String: Any]] = files.map { ["path": $0.key, "type": "blob", "mode": "100644", "size": $0.value.count] }
                return try JSONSerialization.data(withJSONObject: ["truncated": false, "tree": tree])
            }
            let prefix = "/demo/raw/\(self.revision)/"
            XCTAssertTrue(url.path.hasPrefix(prefix))
            guard let data = files[String(url.path.dropFirst(prefix.count))] else { throw URLError(.fileDoesNotExist) }
            return data
        }
        let sources: [DemoRepository.Source] = [.github, .mirror(mirror)]
        let latest = try await DemoRepository.latestCommit(sources: sources, read: read)
        XCTAssertEqual(latest, revision)
        let s = try await DemoRepository.snapshot(sources: sources, read: read)
        XCTAssertEqual(s.files, sample)
        // a commit asked for is fetched as it is, without looking up main
        let pinned = try await DemoRepository.snapshot(commit: revision, sources: [.mirror(mirror)], read: { url in
            XCTAssertNotEqual(url.path, "/demo/commit")
            return try await read(url)
        })
        XCTAssertEqual(pinned.commit, revision)
    }

    /// the copy built into the app is read and checked like a download
    func testFolderFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, data) in sample {
            let f = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: f)
        }
        try Data("notes".utf8).write(to: root.appendingPathComponent("README.md"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent(".git/config.bean"))
        XCTAssertEqual(try DemoRepository.folderFiles(root), sample)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) }
        try DemoRepository.put(try DemoRepository.folderFiles(root), at: dest)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("main.bean")), sample["main.bean"])
    }

    func testRealDemoLedger() async throws {
        guard let path = ProcessInfo.processInfo.environment["LEDGER_DEMO_PATH"] else { throw XCTSkip("Set LEDGER_DEMO_PATH to validate the public demo checkout") }
        let root = URL(fileURLWithPath: path)
        let ledger = loadLedger(root: "main.bean") { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
        XCTAssertTrue(ledger.errors.isEmpty, ledger.errors.map(\.msg).joined(separator: "\n"))
        XCTAssertGreaterThan(ledger.txns.count, 2000)
        XCTAssertEqual(ledger.txns.filter { $0.tags.contains("demo-classic") }.count, 14)
        let subs = subscriptions(ledger)
        XCTAssertTrue(subs.contains { $0.name == "GitHub Copilot" })
        XCTAssertTrue(ledgerEvents(ledger, today: "2026-10-17").contains { $0.tag == "trip-hangzhou" })
        let issues = linkIssues(ledger, subscriptions: subs).filter { $0.txn.tags.contains("demo-classic") }
        XCTAssertTrue(issues.isEmpty, issues.map { $0.title + ": " + $0.detail }.joined(separator: "\n"))
    }
}
