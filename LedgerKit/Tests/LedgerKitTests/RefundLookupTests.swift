import XCTest
@testable import LedgerKit

/// 明细 → 打开一笔支出 → 退款 → 完整表单 → 保存再记 → 关掉空表单后，底下的详情仍用打开时的
/// id / 正文去找。退款会给原交易加上 `^refund`，正文变了；找不到就显示「该交易已不存在」。
/// 走的是退款草稿、`draftText`、`makeOps` 和 `refundLinkOp`（表单保存时追加的那一条），
/// 再按 `noteMoved` 的记法交给 `TxnLookup.find`。不是手写一条无关的 `.link`。
final class RefundLookupTests: XCTestCase {
    private let ledger = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank CNY
    2026-01-01 open Expenses:Food

    2026-10-01 * "Shop" "Lamp"
      Expenses:Food                                       35.00 CNY
      Assets:Bank                                        -35.00 CNY

    """

    /// the same steps as 保存再记 on a refund draft: build the ops, remember the move, apply them, reload
    private func saveRefund(date: String) throws -> (opened: Entry, original: Entry, link: String) {
        let L = loadLedger(root: "main.bean") { _ in self.ledger }
        XCTAssertTrue(L.errors.filter { !$0.soft }.isEmpty, L.errors.map(\.msg).joined(separator: " | "))
        let D = Derived(L, today: "2026-10-25")
        let original = try XCTUnwrap(L.txns.first { $0.payee == "Shop" })
        var draft = refundDraft(original, L, D, defaultFunding: nil)
        draft.date = date
        let saved = trimmedDraft(draftText(draft, L, D))
        XCTAssertFalse(saved.isEmpty, "the refund form did not produce text")
        let layout = RepoLayout.detect(L, main: "main.bean")
        var ops = try makeOps(saved, L, layout: layout, pending: [], fileExists: { _ in false }, single: draftIsSingle(draft, L)).get()
        let origin = try XCTUnwrap(draft.refundOf, "a first refund must remember the purchase it links")
        let linkOp = try XCTUnwrap(refundLinkOp(origin, savedText: saved), saved)
        ops.append(linkOp)
        XCTAssertEqual(linkOp.kind, .link)
        XCTAssertEqual(linkOp.header, original.src.components(separatedBy: "\n").first)
        XCTAssertTrue(linkOp.add?.contains("^" + origin.link) == true, linkOp.add ?? "")

        var moves: [String: String] = [:]
        let moved = movedEntries(ops, L)
        let move = try XCTUnwrap(moved.first { $0.old == original.src }, "the ^refund link was not recorded against the purchase")
        for m in moved {
            moves[normEntryText(m.oldDate + "\u{1}" + m.old)] = m.newDate + "\u{1}" + m.new
        }

        var files = ["main.bean": ledger]
        for path in Set(ops.map(\.path)) {
            files[path] = try applyOps(files[path] ?? "", path: path, ops: ops)
        }
        let after = loadLedger(root: "main.bean", listFiles: { files.keys.sorted() }) { path in
            files[path] ?? ""
        }
        XCTAssertTrue(after.errors.filter { !$0.soft }.isEmpty, after.errors.map(\.msg).joined(separator: " | "))
        XCTAssertTrue(after.txns.contains { $0.tags.contains("refund") && $0.links.contains(origin.link) }, "the refund transaction itself was not written")
        XCTAssertFalse(after.txns.contains { txnKey($0) == txnKey(original) }, "the purchase text should have changed once ^refund was added")

        let opened = try XCTUnwrap(
            TxnLookup(after).find(id: original.id, key: txnKey(original), moves: moves),
            "detail opened on the purchase before the refund must still resolve"
        )
        XCTAssertEqual(normEntryText(opened.date + "\u{1}" + opened.src), normEntryText(move.newDate + "\u{1}" + move.new), opened.src)
        XCTAssertTrue(opened.links.contains(origin.link), opened.src)
        XCTAssertEqual(opened.payee, "Shop")
        return (opened, original, origin.link)
    }

    /// 退款日期在支出之后（保存再记沿用今天，晚于原交易）：原详情仍打开这笔，并带上 ^refund。
    func testRefundSavedAfterThePurchaseStillOpensTheOriginal() throws {
        let (opened, original, link) = try saveRefund(date: "2026-10-25")
        XCTAssertNotEqual(txnKey(opened), txnKey(original))
        XCTAssertEqual(opened.links, [link])
        XCTAssertGreaterThan(opened.id, -1)
    }

    /// 完整表单里把退款日期改到支出之前：插入发生在原交易前面，行号会挪。详情仍要跟到加上 ^refund 的那笔。
    func testRefundDatedBeforeThePurchaseStillOpensTheOriginal() throws {
        let (opened, _, link) = try saveRefund(date: "2026-09-15")
        XCTAssertTrue(opened.links.contains(link), opened.src)
        XCTAssertTrue(opened.src.contains("2026-10-01"), opened.src)
    }
}
