import XCTest
@testable import LedgerKit

/// Thousands of forms, made up from a fixed seed, through the real write path: every one the form accepts must
/// give a balanced entry that the edit form reads back exactly, that 复制为新交易 copies exactly (bar the date),
/// that charges the paying account what was typed, and whose refund takes back what each category was charged.
/// Covers expenses, income and transfers; CNY / HKD / USD accounts; whole numbers, one or two decimals and sums;
/// paying by rate or by the amount charged; discounts; several paying accounts; AA; reimbursement; every fee mode.
/// Fictional accounts only.
final class DraftPropertyTests: XCTestCase {
    /// a fixed-seed generator: the same forms on every run, so a failure can be looked at again
    private struct Seeded {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
        mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
    }

    private let ledger = """
    option "operating_currency" "CNY"
    2020-01-01 open Assets:Bank:DemoBank:Cash CNY
    2020-01-01 open Assets:Bank:DemoHK:Cash HKD
    2020-01-01 open Assets:Cash CNY
    2020-01-01 open Liabilities:CreditCard:DemoBank CNY
    2020-01-01 open Liabilities:CreditCard:DemoUS USD
    2020-01-01 open Assets:Receivable:Personal
    2020-01-01 open Assets:Receivable:Reimbursement
    2020-01-01 open Expenses:Food
    2020-01-01 open Expenses:Shopping
    2020-01-01 open Expenses:Fee:Bank
    2020-01-01 open Income:Salary
    2020-01-01 open Income:Rewards
    2020-01-01 open Equity:Opening-Balances
    2020-01-02 * "Opening"
      Assets:Bank:DemoBank:Cash   100000.00 CNY
      Assets:Bank:DemoHK:Cash     100000.00 HKD
      Assets:Cash                   5000.00 CNY
      Equity:Opening-Balances
    2020-01-03 * "Demo store" "first card use"
      Liabilities:CreditCard:DemoUS  -1.00 USD
      Expenses:Shopping               1.00 USD

    """

    private let paying = ["Assets:Bank:DemoBank:Cash", "Assets:Bank:DemoHK:Cash", "Assets:Cash",
                          "Liabilities:CreditCard:DemoBank", "Liabilities:CreditCard:DemoUS"]

    private func amount(_ r: inout Seeded) -> String {
        let whole = r.int(5000) + (r.chance(10) ? 0 : 1)
        switch r.int(4) {
        case 0: return "\(whole)"
        case 1: return "\(whole).\(r.int(10))"
        case 2: return String(format: "%d.%02d", whole, r.int(100))
        default: return r.chance(30) ? "\(r.int(200) + 1)+\(r.int(99) + 1).5" : String(format: "%d.%02d", whole, r.int(100))
        }
    }

    /// a form as someone could fill it in; the transfer follows its paying account's currency, as the form does
    private func form(_ r: inout Seeded, _ L: Ledger, _ D: Derived) -> Draft {
        var d = Draft()
        d.date = "2026-10-\(10 + r.int(12))"
        d.kind = r.pick([.expense, .expense, .expense, .income, .transfer])
        d.payee = r.chance(70) ? r.pick(["Demo cafe", "Demo shop", "Demo bank"]) : ""
        d.narration = r.chance(60) ? "note" : ""
        d.amount = amount(&r)
        d.currency = r.chance(80) ? "CNY" : "HKD"
        switch d.kind {
        case .expense:
            d.account = r.pick(["Expenses:Food", "Expenses:Shopping"])
            d.funding = r.pick(paying)
            if accountCurrency(d.funding, L, D) != d.currency && r.chance(50) {
                if r.chance(50) { d.byRate = true; d.rate = r.pick(["1.08", "0.92635", "7.1", "1.17912"]) } else { d.paid = amount(&r) }
            }
            if r.chance(15) { d.discount = String(format: "%d.%02d", r.int(5), r.int(100)) }
            if r.chance(10) { d.extraFunds = [ExtraFund(account: "Assets:Cash", amount: "\(r.int(20) + 1)")] }
            if r.chance(10) { d.reimb = true }
            if r.chance(10) { d.split = true; d.shares = [Share(person: "Alice", amount: r.chance(50) ? "" : "\(r.int(20) + 1)")] }
            if r.chance(15) {
                d.transferFee = "\(r.int(10) + 1).\(r.int(10))"
                d.feeMode = r.pick([.added, .separate])
                if d.feeMode == .separate { d.feeFunding = "Assets:Cash" }
            }
        case .income:
            d.account = "Income:Salary"
            d.funding = r.pick(paying)
        default:
            d.funding = r.pick(paying)
            d.currency = accountCurrency(d.funding, L, D) ?? d.currency
            d.to = r.pick(paying.filter { $0 != d.funding })
            if let c = accountCurrency(d.to, L, D), c != d.currency { d.toAmount = amount(&r) }
            if r.chance(25) {
                d.transferFee = "\(r.int(10) + 1)"
                d.feeMode = r.pick(TransferFeeMode.allCases)
                if d.feeMode == .separate { d.feeFunding = "Assets:Cash" }
            }
        }
        return d
    }

    private func written(_ d: Draft, _ L: Ledger, _ D: Derived) -> (text: String, txn: Entry?) {
        let text = draftText(d, L, D)
        let v = validateText(text, L, single: draftIsSingle(d, L))
        return (text, v.ok ? v.txn : nil)
    }

    func testEveryAcceptedFormWritesASoundEntry() {
        let L = loadLedger(root: "main.bean") { _ in self.ledger }
        XCTAssertTrue(L.errors.isEmpty, L.errors.map(\.msg).joined())
        let D = Derived(L, today: "2026-10-22")
        var r = Seeded(state: 20261022)
        var accepted = 0
        var problems: [String: [String]] = [:]
        func note(_ kind: String, _ example: String) { problems[kind, default: []].append(example) }

        for _ in 0..<6000 {
            let d = form(&r, L, D)
            // the form says what is missing; those are not written
            if draftIssue(d, L, D) != nil { continue }
            accepted += 1
            let first = written(d, L, D)
            guard let t = first.txn else { note("not a valid entry", first.text); continue }

            // 编辑: the same entry back, or the source editor (never a different entry)
            if let e = editDraft(t, L, D) {
                let again = written(e, L, D)
                if again.txn.map({ sameTxn($0, t) }) != true { note("edit changes it", first.text + "\n→\n" + again.text) }
            }
            // 复制为新交易: the same entry apart from the date
            var copy = draftFromTxn(t, kind: nil, L, D, defaultFunding: nil)
            copy.date = t.date
            let copied = written(copy, L, D)
            if copied.txn.map({ sameTxn($0, t) }) != true { note("copy differs", first.text + "\n→\n" + copied.text) }

            // a plain expense charges the paying account exactly what was typed
            if d.kind == .expense, d.discount.isEmpty, d.extraFunds.isEmpty, d.transferFee == nil, !d.split,
               accountCurrency(d.funding, L, D) == d.currency, let typed = evalAmount(d.amount) {
                let charged = t.postings.filter { $0.account == d.funding }.compactMap(\.units).reduce(0, +)
                if abs(charged + roundMoney(typed)) > 0.0001 { note("charge differs from the amount", "\(d.amount)\n" + first.text) }
            }
            // a refund takes back what each category was charged (a bank's fee is not refunded)
            if d.kind == .expense, !d.reimb {
                let refund = refundDraft(t, L, D, defaultFunding: nil)
                if draftIssue(refund, L, D) == nil {
                    let back = written(refund, L, D)
                    func charged(_ e: Entry) -> [String: Double] {
                        var m: [String: Double] = [:]
                        for p in e.postings where p.account.hasPrefix("Expenses:") && p.account != "Expenses:Fee:Bank" {
                            if let u = p.units, let c = p.currency { m[p.account + " " + c, default: 0] += u }
                        }
                        return m
                    }
                    if let x = back.txn {
                        let was = charged(t), refunded = charged(x)
                        if was.contains(where: { abs((refunded[$0.key] ?? 0) + $0.value) > 0.0001 }) { note("refund differs", first.text + "\n→\n" + back.text) }
                    } else {
                        note("refund not a valid entry", first.text + "\n→\n" + back.text)
                    }
                }
            }
        }
        // enough of every kind gets through for this to mean something
        XCTAssertGreaterThan(accepted, 3000)
        for (kind, examples) in problems.sorted(by: { $0.key < $1.key }) {
            XCTFail("\(kind): \(examples.count) forms, e.g.\n\(examples.prefix(3).joined(separator: "\n\n"))")
        }
    }
}
