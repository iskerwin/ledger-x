import XCTest
@testable import LedgerKit

/// The Mac's subscription page and its saves, written straight into a folder
final class FolderSubscriptionTests: XCTestCase {
    private var folder: URL!
    private let ledgerText = """
    option "operating_currency" "CNY"
    2023-01-01 open Assets:Bank CNY
    2023-01-01 open Expenses:Subscription CNY
    2023-01-01 open Equity:Opening CNY

    2026-01-05 custom "subscription" "Music" "monthly" 15.00 CNY
      account: "Expenses:Subscription"
      funding: "Assets:Bank"
      payee: "Tunes"
      link: "sub-music"

    2026-01-05 * "Tunes" "Music" ^sub-music
      Expenses:Subscription  15.00 CNY
      Assets:Bank

    2026-02-05 * "Tunes" "Music" ^sub-music
      Expenses:Subscription  15.00 CNY
      Assets:Bank

    """

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ledgerText.write(to: folder.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func ledger() throws -> Ledger { try XCTUnwrap(loadLedger(folder: folder)) }
    private func music() throws -> Subscription { try XCTUnwrap(subscriptions(try ledger()).first { $0.name == "Music" }) }
    private func text() throws -> String { try String(contentsOf: folder.appendingPathComponent("main.bean"), encoding: .utf8) }

    /// a charge recorded on the Mac joins its subscription, as one recorded on the phone does
    func testANewChargeSavedOnTheMacGetsItsSubscriptionsLink() throws {
        let L = try ledger()
        var d = newDraft(.expense, folderDerived(L, config: nil), defaultFunding: nil)
        d.date = "2026-03-05"; d.payee = "Tunes"; d.narration = "Music"
        d.account = "Expenses:Subscription"; d.funding = "Assets:Bank"; d.amount = "15"; d.currency = "CNY"
        _ = try commitFolderSave(try prepareFolderSave(d, folder: folder).get(), folder: folder)
        let charge = try XCTUnwrap(try ledger().txns.first { $0.date == "2026-03-05" })
        XCTAssertTrue(charge.links.contains("sub-music"), charge.src)
    }

    func testPausingWritesAStateLine() throws {
        _ = try commitFolderSave(try prepareFolderSubscription(.state(name: "Music", .paused, date: "2026-03-01", until: nil), folder: folder).get(), folder: folder)
        XCTAssertEqual(try music().status, .paused)
    }

    func testAChangeToASubscriptionChangedSinceIsRefused() throws {
        var d = SubDraft(try music(), mode: .change)
        d.amount = "18"
        try (ledgerText + "\n2026-02-20 custom \"subscription\" \"Music\" \"monthly\" 16.00 CNY\n")
            .write(to: folder.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        let before = try text()
        guard case .failure = prepareFolderSubscription(.save(d), folder: folder) else { return XCTFail("written over a change") }
        XCTAssertEqual(try text(), before)
    }

    func testAPriceChangeAndANewPlanWithItsCharges() throws {
        var change = SubDraft(try music(), mode: .change)
        change.date = "2026-03-01"; change.amount = "18"
        _ = try commitFolderSave(try prepareFolderSubscription(.save(change), folder: folder).get(), folder: folder)
        XCTAssertEqual(try music().amount, 18)

        let L = try ledger()
        let purchase = try XCTUnwrap(L.txns.first { $0.date == "2026-02-05" })
        var fresh = SubDraft(purchase, L)
        fresh.name = "Tunes Extra"
        _ = try commitFolderSave(try prepareFolderSubscription(.save(fresh), folder: folder).get(), folder: folder)
        let extra = try XCTUnwrap(subscriptions(try ledger()).first { $0.name == "Tunes Extra" })
        XCTAssertEqual(extra.charges.count, 1)
        // the name already in use is refused
        guard case .failure = prepareFolderSubscription(.save(fresh), folder: folder) else { return XCTFail("a second Tunes Extra") }
    }

    func testTopupSkipAndDelete() throws {
        let second = try XCTUnwrap(try music().charges.last)
        XCTAssertEqual(subscriptionTopupChoice(second, in: try music()), true)
        XCTAssertNil(subscriptionTopupChoice(try XCTUnwrap(try music().charges.first), in: try music()))
        _ = try commitFolderSave(try prepareFolderSubscription(.topup(second.txn, on: true), folder: folder).get(), folder: folder)
        XCTAssertTrue(try XCTUnwrap(try music().charges.last).topup)

        _ = try commitFolderSave(try prepareFolderSubscription(.skip(name: "Music", due: "2026-03-05"), folder: folder).get(), folder: folder)
        XCTAssertTrue(try music().skips.contains("2026-03-05"))

        _ = try commitFolderSave(try prepareFolderSubscription(.delete(name: "Music", unlink: true), folder: folder).get(), folder: folder)
        XCTAssertNil(subscriptions(try ledger()).first { $0.name == "Music" })
        XCTAssertFalse(try text().contains("^sub-music"))
    }
}
