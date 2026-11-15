import XCTest
@testable import Ledger
import LedgerKit

/// A rebuild reads ledger-x.json and the .bql files off the main thread: the main file ledger-x.json names, the query
/// directives and each .bql file's queries still come through, with a queued change to a .bql file applied
@MainActor
final class RebuildConfigTests: XCTestCase {
    func testTheConfiguredMainFileAndEveryQueryAreRead() async throws {
        let store = Store()
        var config = RepoConfig()
        config.id = "rebuild-config-test-" + UUID().uuidString
        config.kind = .local
        config.folderName = config.id
        let root = FolderBackend.localRoot(config.folderName)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("books"), withIntermediateDirectories: true)
        addTeardownBlock { @MainActor in try? FileManager.default.removeItem(at: root) }
        try "2026-01-01 open Assets:Cash CNY\n".write(to: root.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        try """
        2026-01-01 open Assets:Bank CNY
        2026-01-01 query "Bank" "SELECT account WHERE account ~ 'Bank'"

        """.write(to: root.appendingPathComponent("books/root.bean"), atomically: true, encoding: .utf8)
        try "-- Cash\nSELECT account WHERE account ~ 'Cash'\n".write(to: root.appendingPathComponent("saved.bql"), atomically: true, encoding: .utf8)
        try #"{"version":1,"main":"books/root.bean"}"#.write(to: root.appendingPathComponent(LedgerXConfig.path), atomically: true, encoding: .utf8)
        store.cfg = config
        store.mainFile = "main.bean"
        await store.refresh()
        XCTAssertEqual(store.main, "books/root.bean")
        XCTAssertEqual(store.L?.files, ["books/root.bean"])
        XCTAssertEqual(store.ledgerQueries.map(\.name).sorted(), ["Bank", "Cash"])

        var op = Op(kind: .write, path: "saved.bql")
        op.text = "-- Assets\nSELECT account\n"
        XCTAssertEqual(Store.ledgerQueries(try XCTUnwrap(store.L), files: try XCTUnwrap(store.tree).files, ops: [op]).map(\.name).sorted(),
                       ["Assets", "Bank"])
    }
}
