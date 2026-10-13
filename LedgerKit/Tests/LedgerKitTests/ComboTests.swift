import XCTest
@testable import LedgerKit

/// 组合付款, 优惠 and the accounts left out of 净资产 / 资产负债表
final class ComboTests: XCTestCase {
    private let base = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank CNY
    2026-01-01 open Assets:Alipay CNY
    2026-01-01 open Assets:Receivable:Reimbursement
    2026-01-01 open Liabilities:CreditCard:CMB CNY
    2026-01-01 open Liabilities:CreditCard:Company CNY
    2026-01-01 open Expenses:Shopping:Household
    2026-01-01 open Income:Rewards
    2026-01-01 open Assets:Bank:USD USD

    """
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private func draft() -> Draft {
        var d = Draft()
        d.kind = .expense; d.date = "2026-10-13"; d.payee = "超市"; d.narration = "日用品"
        d.account = "Expenses:Shopping:Household"; d.funding = "Assets:Alipay"; d.amount = "100"; d.currency = "CNY"
        return d
    }

    func testComboAndDiscount() {
        let L = ledger(base)
        let D = Derived(L, today: "2026-10-13")
        var d = draft()
        d.extraFunds = [ExtraFund(account: "Liabilities:CreditCard:CMB", amount: "40")]
        d.discount = "10"
        let t = draftText(d, L, D)
        // the main account pays what is left; the discount is income
        XCTAssertTrue(t.contains("Expenses:Shopping:Household") && t.contains("100.00 CNY"), t)
        XCTAssertTrue(t.contains("Assets:Alipay") && t.contains("-50.00 CNY"), t)
        XCTAssertTrue(t.contains("Liabilities:CreditCard:CMB") && t.contains("-40.00 CNY"), t)
        XCTAssertTrue(t.contains("Income:Rewards") && t.contains("-10.00 CNY"), t)
        XCTAssertTrue(validateText(t, L).ok, validateText(t, L).msg ?? "")

        // written back: the simple form, with the same parts
        let L2 = ledger(base + t + "\n")
        let e = L2.txns.last!
        XCTAssertTrue(isComboPayment(e))
        XCTAssertFalse(isComplex(e))
        let back = draftFromTxn(e, L2, Derived(L2, today: "2026-10-13"), defaultFunding: nil)
        XCTAssertEqual(back.kind, .expense)
        XCTAssertEqual(back.amount, "100")
        XCTAssertEqual(back.funding, "Assets:Alipay")
        XCTAssertEqual(back.extraFunds.map { $0.account }, ["Liabilities:CreditCard:CMB"])
        XCTAssertEqual(back.extraFunds.first?.amount, "40")
        XCTAssertEqual(back.discount, "10")
        XCTAssertEqual(back.discountAccount, "Income:Rewards")
        // counted as a 100 expense and 10 of income
        XCTAssertEqual(classify(e, L2).kind, .expense)
        XCTAssertEqual(abs(classify(e, L2).amount), 100, accuracy: 0.001)
    }

    func testComboLimits() {
        let L = ledger(base)
        let D = Derived(L, today: "2026-10-13")
        var d = draft()
        // the parts can't come to more than the price
        d.extraFunds = [ExtraFund(account: "Liabilities:CreditCard:CMB", amount: "120")]
        XCTAssertEqual(draftText(d, L, D), "")
        // another currency isn't supported in a combination
        d.extraFunds = [ExtraFund(account: "Assets:Bank:USD", amount: "10")]
        XCTAssertEqual(draftText(d, L, D), "")
        // the discount has to leave something to pay
        d.extraFunds = []; d.discount = "100"
        XCTAssertEqual(draftText(d, L, D), "")
        // a reimbursed expense ignores the discount and is entered at what was paid; other accounts still work
        d.discount = "10"; d.reimb = true
        d.extraFunds = [ExtraFund(account: "Liabilities:CreditCard:CMB", amount: "30")]
        let t = draftText(d, L, D)
        XCTAssertFalse(t.contains("Income:Rewards"), t)
        XCTAssertTrue(t.contains("Assets:Alipay") && t.contains("-70.00 CNY"), t)
        let L2 = ledger(base + t + "\n")
        let back = draftFromTxn(L2.txns.last!, L2, Derived(L2, today: "2026-10-13"), defaultFunding: nil)
        XCTAssertTrue(back.reimb)
        XCTAssertEqual(back.extraFunds.first?.amount, "30")
        // an empty row added and left is ignored
        var e = draft()
        e.extraFunds = [ExtraFund(account: "")]
        XCTAssertTrue(draftText(e, L, D).contains("-100.00 CNY"))
        XCTAssertFalse(hasCombo(e))

        // what the form says about it
        var f = draft()
        f.extraFunds = [ExtraFund(account: "Liabilities:CreditCard:CMB", amount: "40")]
        f.discount = "10"
        XCTAssertNil(comboIssue(f, L, D))
        XCTAssertEqual(comboRest(f), 50)
        f.extraFunds[0].amount = "95"
        XCTAssertNotNil(comboIssue(f, L, D))
        f.extraFunds[0].account = "Assets:Alipay"
        XCTAssertNotNil(comboIssue(f, L, D))
    }

    func testExclusions() {
        let L = ledger(base + """
        2026-09-01 * "工资"
          Assets:Bank  1000.00 CNY
          Income:Rewards
        2026-09-02 * "公司卡"
          Expenses:Shopping:Household  300.00 CNY
          Liabilities:CreditCard:Company
        2026-09-03 * "招行"
          Expenses:Shopping:Household  100.00 CNY
          Liabilities:CreditCard:CMB

        """)
        let all = netWorthNow(L)
        XCTAssertEqual(all.assets + all.liabilities, 600, accuracy: 0.001)
        // a parent excludes its sub-accounts
        let some = netWorthNow(L, exclude: ["Liabilities:CreditCard:Company"])
        XCTAssertEqual(some.assets + some.liabilities, 900, accuracy: 0.001)
        XCTAssertEqual(netWorthNow(L, exclude: ["Liabilities:CreditCard"]).liabilities, 0, accuracy: 0.001)
        XCTAssertEqual(netWorthSeries(L, today: "2026-10-13", exclude: ["Liabilities:CreditCard:Company"]).last?.netWorth ?? 0, 900, accuracy: 0.001)
        let bs = balanceSheet(L, at: nil, exclude: ["Liabilities:CreditCard:Company"])
        XCTAssertEqual(bs.liabilities.total, -100, accuracy: 0.001)
        XCTAssertFalse(isExcluded("Liabilities:CreditCard:CMB", ["Liabilities:CreditCard:CM"]))

        // renaming an account carries the settings along; nothing to change gives nil
        var c = LedgerXConfig()
        c.netWorthExclude = ["Liabilities:CreditCard:Company"]
        c.balanceExclude = ["Liabilities:CreditCard"]
        let r = c.renamingAccount("Liabilities:CreditCard", to: "Liabilities:Card")!
        XCTAssertEqual(r.netWorthExclude, ["Liabilities:Card:Company"])
        XCTAssertEqual(r.balanceExclude, ["Liabilities:Card"])
        XCTAssertNil(c.renamingAccount("Assets:Bank", to: "Assets:Money"))
        // read and written under their own keys
        XCTAssertTrue(c.json().contains("\"networth_exclude\""))
        XCTAssertEqual(LedgerXConfig.parse(c.json())?.balanceExclude, ["Liabilities:CreditCard"])
    }
}
