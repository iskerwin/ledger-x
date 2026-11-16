import XCTest
@testable import LedgerKit

/// what the subscription pages write, shared by the phone and the Mac
final class SubscriptionEditTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private let text = """
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

    2026-02-05 * "Tunes" "Music"
      Expenses:Subscription  15.00 CNY
      Assets:Bank

    """

    private func music(_ L: Ledger) throws -> Subscription { try XCTUnwrap(subscriptions(L).first { $0.name == "Music" }) }

    func testANewPlanIsInsertedWithItsSummary() throws {
        var d = SubDraft(currency: "CNY")
        d.name = "News"; d.amount = "8"; d.start = "2026-03-01"; d.account = "Expenses:Subscription"; d.funding = "Assets:Bank"
        d.link = "sub-news"
        var inserted: [(String, String)] = []
        let ops = try XCTUnwrap(d.ops { text, label in inserted.append((text, label)); return [Op(kind: .insert, path: "x")] })
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(inserted.first?.0, d.text)
        let first = try XCTUnwrap(inserted.first?.0.components(separatedBy: "\n").first)
        XCTAssertTrue(first.hasPrefix("2026-03-01 custom \"subscription\" \"News\" \"monthly\""), first)
        XCTAssertTrue(first.hasSuffix(" 8.00 CNY"), first)
        XCTAssertTrue(d.nameTaken([]) == false)
    }

    func testASecondChangeOnOneDayReplacesThatDaysLineAndKeepsWhatItChanged() throws {
        let L = ledger(text + """
        2026-03-01 custom "subscription" "Music" "monthly" 18.00 CNY
          payee: "Tunes Plus"

        """)
        let s = try music(L)
        var d = SubDraft(s, mode: .change)
        d.date = "2026-03-01"; d.amount = "20"
        let ops = try XCTUnwrap(d.ops { _, _ in XCTFail("not inserted"); return nil })
        XCTAssertEqual(ops.map(\.kind), [.replace])
        XCTAssertTrue(ops[0].text?.contains("20.00 CNY") ?? false)
        // the payee the earlier line changed stays
        XCTAssertTrue(ops[0].text?.contains("payee: \"Tunes Plus\"") ?? false, ops[0].text ?? "")
        XCTAssertEqual(subscriptionMergedChange("2026-03-01 x\n  next: 2026-04-01", into: "2026-03-01 y\n  next: 2026-05-01\n  payee: \"A\""),
                       "2026-03-01 x\n  payee: \"A\"\n  next: 2026-04-01")
    }

    func testCorrectingANameRenamesEveryLine() throws {
        let L = ledger(text + """
        2026-03-01 custom "subscription" "Music" "monthly" 18.00 CNY

        """)
        var d = SubDraft(try music(L), mode: .correct)
        d.name = "Songs"
        let ops = try XCTUnwrap(d.ops { _, _ in nil })
        XCTAssertEqual(ops.count, 2)
        XCTAssertTrue(ops.allSatisfy { $0.kind == .replace || $0.kind == .remove || $0.text?.contains("\"Songs\"") == true })
        XCTAssertEqual(ops.filter { $0.silent == true }.count, 1)
    }

    func testLinkingUnlinkingAndDeleting() throws {
        let L = ledger(text)
        let s = try music(L)
        let loose = try XCTUnwrap(L.txns.first { $0.date == "2026-02-05" })
        let link = try XCTUnwrap(subscriptionLinkOps([loose], link: s.link, label: "L", files: ["main.bean": text]))
        XCTAssertEqual(link.map(\.kind), [.link])
        XCTAssertEqual(link[0].add, " ^sub-music")
        XCTAssertEqual(link[0].label, "L")
        // the file changed under it: refused
        XCTAssertNil(subscriptionLinkOps([loose], link: s.link, label: nil, files: ["main.bean": base]))
        XCTAssertEqual(subscriptionUnlinkAllOps(s).count, 1)
        let delete = subscriptionDeleteOps(s, unlink: true)
        XCTAssertEqual(delete.map(\.kind), [.remove, .replace])
        XCTAssertNotNil(subscriptionTopupOp(s.charges[0], true, s))
        XCTAssertNil(subscriptionTopupOp(s.charges[0], false, s))
    }

    func testANewChargeOfAPlanGetsItsLink() throws {
        let L = ledger(text)
        var op = Op(kind: .insert, path: "main.bean")
        op.text = "2026-03-05 * \"Tunes\" \"Music\"\n  Expenses:Subscription  15.00 CNY\n  Assets:Bank"
        let (ops, names) = autoLinkSubscriptions([op], L, subs: subscriptions(L))
        XCTAssertEqual(names, ["Music"])
        XCTAssertTrue(ops[0].text?.hasPrefix("2026-03-05 * \"Tunes\" \"Music\" ^sub-music") ?? false)
    }

    private var base: String { text.components(separatedBy: "2026-01-05 custom")[0] }
}
