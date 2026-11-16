import XCTest
@testable import LedgerKit

/// what the reimbursement pages write, shared by the phone and the Mac
final class ReimbursementEditTests: XCTestCase {
    private let receivable = "Assets:Receivable:Reimbursement"
    private let text = """
    2026-03-02 * "Hotel" "Trip"
      Assets:Receivable:Reimbursement  300.00 CNY
      Assets:Bank

    2026-03-03 * "Taxi" "Trip" #reimbursed
      Assets:Receivable:Reimbursement  50.00 CNY
      Assets:Bank

    """

    private func entries() -> [Entry] { parseFile(text, file: "main.bean").entries }

    private func payment(got: Double, keepOpen: Bool = false) -> ReimbursementPayment {
        ReimbursementPayment(date: "2026-03-20", payee: " ACME ", account: "Assets:Bank", link: "reimburse-acme-20260320",
                             owed: 350, got: got, currency: "CNY", receivable: receivable, keepOpen: keepOpen)
    }

    private func lines(_ p: ReimbursementPayment) -> [String] {
        p.text.components(separatedBy: "\n").dropFirst().map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
    }

    func testRepaymentExactOverShortAndKeptOpen() {
        let exact = payment(got: 350)
        XCTAssertTrue(exact.text.hasPrefix("2026-03-20 * \"ACME\" \"报销入账-20260320\" #reimbursement ^reimburse-acme-20260320"), exact.text)
        XCTAssertEqual(lines(exact).filter { !$0.isEmpty }.count, 2)
        XCTAssertTrue(lines(payment(got: 360)).contains("Income:ReimbExcess -10.00 CNY"))
        XCTAssertTrue(lines(payment(got: 340)).contains("Income:ReimbExcess 10.00 CNY"))
        // kept open: only what came back leaves the receivable
        let open = lines(payment(got: 340, keepOpen: true))
        XCTAssertTrue(open.contains("Assets:Receivable:Reimbursement -340.00 CNY"), open.joined(separator: "\n"))
        XCTAssertFalse(open.contains { $0.hasPrefix("Income:ReimbExcess") })
        XCTAssertEqual(payment(got: 0).text, "")
        var noAccount = payment(got: 350)
        noAccount.account = ""
        XCTAssertEqual(noAccount.text, "")
    }

    func testAdvancesAreLinkedOnceAndTaggedOnlyWhereNeeded() throws {
        let es = entries()
        let ops = try XCTUnwrap(advanceLinkOps(es + [es[0]], link: "reimburse-x", label: "L", files: ["main.bean": text]))
        XCTAssertEqual(ops.map(\.add), [" #reimbursed ^reimburse-x", " ^reimburse-x"])
        XCTAssertEqual(ops.map(\.label), ["L", nil])
        XCTAssertEqual(ops.map(\.silent), [nil, true])
        XCTAssertEqual(ops[1].headerLine, 5)
        XCTAssertTrue(try XCTUnwrap(advanceLinkOps(es, link: "reimburse-x", label: nil, files: ["main.bean": text])).allSatisfy { $0.silent == true })
        // the file changed under it: refused
        XCTAssertNil(advanceLinkOps(es, link: "reimburse-x", label: nil, files: ["main.bean": text.replacingOccurrences(of: "Hotel", with: "Inn")]))
        XCTAssertNil(advanceLinkOps(es, link: "reimburse-x", label: nil, files: [:]))
    }

    func testAnAdvancesFieldsAndALinkTakenOff() throws {
        let hotel = entries()[0]
        let set = try XCTUnwrap(advanceMetaOp(hotel, receivable: receivable, key: voucherMeta, value: "发票"))
        XCTAssertTrue(set.text?.contains("voucher:") == true && set.text?.contains("发票") == true, set.text ?? "")
        XCTAssertNil(advanceMetaOp(hotel, receivable: receivable, key: voucherMeta, value: nil))
        let linked = try XCTUnwrap(parseFile(text.replacingOccurrences(of: "\"Trip\"\n  Assets:Receivable:Reimbursement  300", with: "\"Trip\" ^reimburse-x\n  Assets:Receivable:Reimbursement  300"), file: "main.bean").entries.first)
        let off = try XCTUnwrap(linkEditOp(linked, link: "reimburse-x", remove: true))
        XCTAssertFalse(off.text?.contains("^reimburse-x") ?? true)
        XCTAssertNil(linkEditOp(hotel, link: "reimburse-x", remove: true))
    }
}
