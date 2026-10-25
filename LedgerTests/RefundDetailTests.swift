import XCTest
@testable import Ledger
import LedgerKit

/// A refund links the purchase it refunds, which rewrites that purchase's text. Its page, still open underneath the
/// form, finds it again after the save and after the sync that follows. Fictional data only.
@MainActor
final class RefundDetailTests: XCTestCase {
    private func fixture(_ text: String) async throws -> Store {
        let store = Store()
        var config = RepoConfig()
        config.id = "refund-detail-test-" + UUID().uuidString
        config.kind = .local
        config.folderName = config.id
        let root = FolderBackend.localRoot(config.folderName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: root.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        store.cfg = config
        store.pending = []
        store.mainFile = "main.bean"
        await store.refresh()
        addTeardownBlock { @MainActor in
            await store.waitForSavedSync()
            try? FileManager.default.removeItem(at: root)
        }
        return store
    }

    func testTheRefundedPurchaseIsFoundAfterTheSaveAndTheSync() async throws {
        let store = try await fixture("""
        2026-01-01 open Assets:Bank:DemoBank CNY
        2026-01-01 open Expenses:Food
        2026-01-01 open Equity:Opening

        2026-01-01 * "Opening"
          Assets:Bank:DemoBank 100.00 CNY
          Equity:Opening -100.00 CNY

        2026-10-17 * "Cafe" "Coffee"
          Expenses:Food                                        12.00 CNY
          Assets:Bank:DemoBank                                -12.00 CNY

        2026-10-18 * "Bakery" "Bread"
          Expenses:Food                                         8.00 CNY
          Assets:Bank:DemoBank                                 -8.00 CNY

        """)
        let L = try XCTUnwrap(store.L), D = try XCTUnwrap(store.D)
        let t = try XCTUnwrap(L.txns.first { $0.payee == "Cafe" })
        let dest = TxDest(t)
        var d = refundDraft(t, L, D, defaultFunding: nil)
        d.amount = "12"
        store.draft = d
        let saved = await store.saveDraft(onQueued: nil)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.txn(dest.id, key: dest.key)?.links.isEmpty, false, "after the save")
        let v0 = store.version
        await store.waitForSavedSync()
        XCTAssertEqual(store.version, v0, "the sync after the save changed nothing: no second rebuild")
        XCTAssertTrue(store.pending.isEmpty)
        let found = store.txn(dest.id, key: dest.key)
        XCTAssertNotNil(found, "after the sync")
        XCTAssertEqual(found?.payee, "Cafe")
        XCTAssertEqual(found?.links.isEmpty, false)

        // refunded again from the same page: the purchase has its link already
        let L2 = try XCTUnwrap(store.L), D2 = try XCTUnwrap(store.D)
        var d2 = refundDraft(try XCTUnwrap(found), L2, D2, defaultFunding: nil)
        d2.amount = "2"
        store.draft = d2
        let savedAgain = await store.saveDraft(onQueued: nil)
        XCTAssertTrue(savedAgain)
        XCTAssertNotNil(store.txn(dest.id, key: dest.key), "after a second refund")
        let v1 = store.version
        await store.waitForSavedSync()
        XCTAssertEqual(store.version, v1, "no second rebuild")
        XCTAssertNotNil(store.txn(dest.id, key: dest.key), "after a second refund and its sync")

        // The background undo calculation must restore exactly the saved files, including refund links.
        let second = try XCTUnwrap(store.history.first)
        let first = try XCTUnwrap(store.history.first { $0.id != second.id && $0.undone == nil })
        let revertedSecond = await store.revert(second.id)
        XCTAssertTrue(revertedSecond)
        await store.waitForSavedSync()
        XCTAssertNotNil(store.txn(dest.id, key: dest.key))
        let revertedFirst = await store.revert(first.id)
        XCTAssertTrue(revertedFirst)
        await store.waitForSavedSync()
        XCTAssertEqual(store.L?.txns.filter { $0.tags.contains("refund") }.count, 0)
        XCTAssertEqual(store.L?.txns.first { $0.payee == "Cafe" }?.src, t.src)
    }
}
