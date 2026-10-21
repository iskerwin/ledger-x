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

    /// paid from a HKD card: the receipt's rate kept as it is; an exchange between accounts is #fx
    func testRateAndExchange() {
        let L = ledger(base + """
        2026-01-01 open Assets:Bank:HSBC HKD
        2026-01-01 open Assets:Bank:ZABank:Cash HKD

        """)
        let D = Derived(L, today: "2026-10-13")
        var d = draft()
        d.funding = "Assets:Bank:HSBC"; d.amount = "23"; d.byRate = true; d.rate = "1.17912"
        let t = draftText(d, L, D)
        XCTAssertTrue(t.contains("23.00 CNY @ 1.17912 HKD") && t.contains("-27.12 HKD"), t)
        XCTAssertTrue(validateText(t, L).ok, validateText(t, L).msg ?? "")
        let L2 = ledger(base + "2026-01-01 open Assets:Bank:HSBC HKD\n" + t + "\n")
        let back = draftFromTxn(L2.txns.last!, L2, Derived(L2, today: "2026-10-13"), defaultFunding: nil)
        XCTAssertTrue(back.byRate)
        XCTAssertEqual(back.rate, "1.17912")
        XCTAssertEqual(back.paid, "27.12")

        // an exchange: #fx, the receiving institution as payee; a plain transfer stays #transfer
        var x = Draft()
        x.kind = .transfer; x.date = "2026-10-13"; x.funding = "Assets:Bank"; x.to = "Assets:Bank:ZABank:Cash"
        x.amount = "500"; x.currency = "CNY"; x.toAmount = "585.42"
        let fx = draftText(x, L, D)
        XCTAssertTrue(fx.contains("\"ZABank\"") && fx.contains("#fx") && !fx.contains("#transfer"), fx)
        XCTAssertTrue(validateText(fx, L).ok)
        x.to = "Assets:Alipay"; x.toAmount = ""
        let tr = draftText(x, L, D)
        XCTAssertTrue(tr.contains("#transfer") && tr.contains("\"Transfer\""), tr)
        XCTAssertEqual(institution("Assets:Bank:HSBC"), "HSBC")
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

        // the shared settings: read back under their own keys; empty lists and blanks aren't written
        var d = LedgerXConfig()
        d.main = "ledger.bean"; d.defaultFunding = "Assets:Bank"; d.defaultCurrency = "CNY"; d.largeExpense = 1000
        d.alertsConfirmed = ["b", "a", "a"]; d.linksIgnored = []; d.templatesPinned = ["x"]
        let j = d.json()
        XCTAssertTrue(j.contains("\"default_funding\"") && j.contains("\"large_expense\"") && !j.contains("links_ignored"), j)
        let back = LedgerXConfig.parse(j)!
        XCTAssertEqual(back.main, "ledger.bean")
        XCTAssertEqual(back.alertsConfirmed, ["a", "b"])
        XCTAssertEqual(back.templatesPinned, ["x"])
        XCTAssertEqual(back.largeExpense, 1000)
        XCTAssertEqual(d.renamingAccount("Assets:Bank", to: "Assets:Cash")?.defaultFunding, "Assets:Cash")
        // {root_lower} in a file pattern
        XCTAssertEqual(RepoLayout.expand("accounts/{root_lower}.bean", date: "2026-01-01", account: "Expenses:Food"), "accounts/expenses.bean")
    }
}
