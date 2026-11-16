import XCTest
@testable import LedgerKit

/// The Mac's reimbursement saves, written straight into a folder
final class FolderReimbursementTests: XCTestCase {
    private var folder: URL!
    private let d1 = Day.shift(Day.today(), -10)
    private let d2 = Day.shift(Day.today(), -9)
    private let receivable = "Assets:Receivable:Reimbursement"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = """
        option "operating_currency" "CNY"
        2023-01-01 open Assets:Bank
        2023-01-01 open Assets:Receivable:Reimbursement
        2023-01-01 open Income:ReimbExcess
        2023-01-01 open Expenses:Travel

        \(d1) * "Hotel" "Trip"
          Assets:Receivable:Reimbursement  300.00 CNY
          Assets:Bank

        \(d2) * "Taxi" "Trip"
          Assets:Receivable:Reimbursement  50.00 CNY
          Assets:Bank

        \(d2) * "Lunch" "Trip"
          Assets:Receivable:Reimbursement  20.00 USD
          Assets:Bank

        """
        try text.write(to: folder.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func ledger() throws -> Ledger { try XCTUnwrap(loadLedger(folder: folder)) }
    private func derived() throws -> Derived { folderDerived(try ledger(), config: nil) }
    private func cny() throws -> [Entry] { try derived().unclaimed.filter { $0.currency == "CNY" }.map(\.t) }

    private func payment(owed: Double, got: Double, link: String = "reimburse-acme-20260320", keepOpen: Bool = false) -> ReimbursementPayment {
        ReimbursementPayment(date: Day.today(), payee: "ACME", account: "Assets:Bank", link: link, owed: owed, got: got, currency: "CNY",
                             receivable: "", keepOpen: keepOpen)
    }

    private func save(_ change: ReimbursementChange) throws {
        _ = try commitFolderSave(try prepareFolderReimbursement(change, folder: folder).get(), folder: folder)
    }

    func testPayingPickedAdvancesLinksThemAndSettles() throws {
        try save(.pay(payment(owed: 350, got: 350), advances: try cny()))
        let D = try derived()
        XCTAssertEqual(D.unclaimed.map(\.currency), ["USD"], "the other currency stays waiting")
        XCTAssertTrue(D.openLinks.isEmpty)
        XCTAssertEqual(D.byLink["reimburse-acme-20260320"]?.count, 3)
        XCTAssertTrue(try ledger().txns.filter { $0.payee == "Taxi" }.allSatisfy { $0.tags.contains("reimbursed") })
    }

    func testAShortfallKeptOpenIsPaidLaterOnItsLink() throws {
        try save(.pay(payment(owed: 350, got: 300, keepOpen: true), advances: try cny()))
        let open = try XCTUnwrap(try derived().openLinks.first)
        XCTAssertEqual(open.amount, 50)
        try save(.pay(payment(owed: 50, got: 50, link: open.link), advances: []))
        XCTAssertTrue(try derived().openLinks.isEmpty)
    }

    func testWhatChangedSinceTheFormWasDrawnIsRefused() throws {
        // the total shown no longer matches
        XCTAssertThrowsError(try prepareFolderReimbursement(.pay(payment(owed: 340, got: 340), advances: try cny()), folder: folder).get())
        // an open link owing something else
        XCTAssertThrowsError(try prepareFolderReimbursement(.pay(payment(owed: 50, got: 50, link: "reimburse-none"), advances: []), folder: folder).get())
        // an advance already claimed since
        let es = try cny()
        try save(.pay(payment(owed: 50, got: 50), advances: [es[1]]))
        XCTAssertThrowsError(try prepareFolderReimbursement(.pay(payment(owed: 350, got: 350, link: "reimburse-b"), advances: es), folder: folder).get())
        // a link already used
        XCTAssertThrowsError(try prepareFolderReimbursement(.pay(payment(owed: 300, got: 300), advances: [es[0]]), folder: folder).get())
    }

    func testAnAdvancesFieldsAreSetAndCleared() throws {
        let hotel = try cny()[0]
        try save(.fields(hotel, category: "Expenses:Travel", voucher: "发票"))
        let set = try XCTUnwrap(try ledger().txns.first { $0.payee == "Hotel" })
        let p = try XCTUnwrap(set.postings.first { $0.account == receivable })
        XCTAssertEqual(advanceCategory(p), "Expenses:Travel")
        XCTAssertEqual(p.meta[voucherMeta]?.stringValue, "发票")
        try save(.fields(set, category: "Expenses:Travel", voucher: nil))
        let cleared = try XCTUnwrap(try ledger().txns.first { $0.payee == "Hotel" }?.postings.first { $0.account == receivable })
        XCTAssertNil(cleared.meta[voucherMeta])
        XCTAssertEqual(advanceCategory(cleared), "Expenses:Travel")
        // nothing to change
        XCTAssertThrowsError(try prepareFolderReimbursement(.fields(try XCTUnwrap(try ledger().txns.first { $0.payee == "Hotel" }), category: "Expenses:Travel", voucher: nil), folder: folder).get())
    }

    func testAnAdvanceTakenOffGoesBackToWaiting() throws {
        try save(.pay(payment(owed: 350, got: 300, keepOpen: true), advances: try cny()))
        let taxi = try XCTUnwrap(try ledger().txns.first { $0.payee == "Taxi" })
        try save(.remove(taxi, link: "reimburse-acme-20260320"))
        XCTAssertEqual(try cny().map(\.payee), ["Taxi"])
    }
}
