import XCTest
@testable import LedgerKit

/// The Mac's 登记退款 saves on the folder path: the purchase gets the refund's link too, as on the phone
final class FolderRefundTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        2025-01-01 open Assets:Bank CNY
        2025-01-01 open Expenses:Shopping CNY
        2025-01-01 open Equity:Opening CNY

        2026-01-01 * "Opening"
          Assets:Bank  1000.00 CNY
          Equity:Opening  -1000.00 CNY

        2026-03-02 * "Shop" "Shoes"
          Expenses:Shopping  200.00 CNY
          Assets:Bank

        """.write(to: folder.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testARefundLinksThePurchase() throws {
        let ledger = try XCTUnwrap(loadLedger(folder: folder))
        let purchase = try XCTUnwrap(ledger.txns.first { $0.payee == "Shop" })
        let draft = refundDraft(purchase, ledger, folderDerived(ledger, config: nil), defaultFunding: nil)
        let link = draft.link
        XCTAssertFalse(link.isEmpty)
        let save = try prepareFolderSave(draft, folder: folder).get()
        _ = try commitFolderSave(save, folder: folder)
        let after = try XCTUnwrap(loadLedger(folder: folder))
        let shop = after.txns.filter { $0.payee == "Shop" }
        XCTAssertEqual(shop.count, 2)
        // both the purchase and its refund carry the link
        XCTAssertTrue(shop.allSatisfy { $0.links.contains(link) }, shop.map(\.src).joined(separator: "\n"))
    }
}
