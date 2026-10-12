import XCTest
@testable import LedgerKit

/// 往来: people, the company's account, loans, AA and settling what is left
final class CounterpartyTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private let base = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank CNY
    2026-01-01 open Assets:Receivable:Employer
      name: "公司往来"
    2026-01-01 open Assets:Receivable:Reimbursement
    2026-01-01 open Assets:Receivable:Personal
    2026-01-01 open Liabilities:Loan:WuYi
      name: "五姨"
    2026-01-01 open Liabilities:Loan:Rabi
    2026-01-01 open Assets:Receivable:Personal:Old
    2026-01-01 open Expenses:Food CNY
    2026-01-01 open Income:Salary CNY
    2026-01-01 open Equity:Opening

    2026-01-02 * "Opening"
      Assets:Bank  10000.00 CNY
      Liabilities:Loan:WuYi  -3000.00 CNY
      Liabilities:Loan:Rabi  -6000.00 CNY
      Equity:Opening

    2026-02-01 * "五姨" "代付"
      Assets:Receivable:Personal  500.00 CNY
        person: "五姨"
      Assets:Bank

    2026-02-03 * "Old" "借出"
      Assets:Receivable:Personal:Old  100.00 CNY
      Assets:Bank

    2026-03-01 * "Old" "收回"
      Assets:Receivable:Personal:Old  -100.00 CNY
      Assets:Bank

    2026-08-10 * "公司" "工资" ^salary-co-202607
      Income:Salary  -10000.00 CNY
      Assets:Receivable:Employer  200.00 CNY
      Assets:Bank

    2026-09-10 * "公司" "工资" ^salary-co-202608
      Income:Salary  -10000.00 CNY
      Assets:Receivable:Employer  -50.00 CNY
      Assets:Bank

    2026-09-12 * "公司" "补发" ^salary-co-202607
      Assets:Receivable:Employer  -200.00 CNY
      Assets:Bank

    2026-09-20 * "公司" "差额"
      Assets:Receivable:Employer  30.00 CNY
      Assets:Bank

    """

    func testPeople() {
        let L = ledger(base)
        let ps = people(L)
        XCTAssertEqual(ps.map { $0.name }, ["Rabi", "五姨", "Old"])
        let wy = ps[1]
        XCTAssertEqual(wy.net["CNY"], -2500)     // you paid 500 for her and borrowed 3000 from her
        XCTAssertEqual(wy.balances["Assets:Receivable:Personal"]?["CNY"], 500)
        XCTAssertEqual(wy.loan(L), "Liabilities:Loan:WuYi")
        // the older layout: a sub-account without person: is its own person
        XCTAssertTrue(ps[2].settled)
        XCTAssertEqual(ps[2].last, "2026-03-01")
        XCTAssertEqual(personEntries(L, "五姨").count, 2)
        XCTAssertEqual(loanKey("Liabilities:Loan:WuYi:Car"), "WuYi")
        XCTAssertNil(loanPerson(L, "Assets:Receivable:Employer"))
        // a posting that names nobody is shown as such, and warned about when written
        let t = "2026-10-01 * \"x\" \"y\"\n  Assets:Receivable:Personal  10.00 CNY\n  Assets:Bank\n"
        XCTAssertEqual(validateText(t, L).warnings.count, 1)
        XCTAssertTrue(people(ledger(base + t)).contains { $0.unnamed && $0.net["CNY"] == 10 })
    }

    func testEmployer() {
        let e = employerOpen(ledger(base))
        XCTAssertEqual(e.total["CNY"], -20)
        // July's difference was paid; August's overpayment and an unlinked 30 are still open
        XCTAssertEqual(e.open.map { $0.link }, ["salary-co-202608", nil])
        XCTAssertEqual(e.open.map { $0.amount }, [-50, 30])
    }

    func testEmployerSeveralMonthsAtOnce() {
        // a payslip netted against a reimbursement carries both links; one entry settles two months
        let L = ledger(base + """
        2026-09-25 * "公司" "工资" ^salary-co-202609
          Income:Salary  -10000.00 CNY
          Assets:Receivable:Employer  -1910.00 CNY
          Assets:Bank

        2026-09-26 * "公司" "工资" ^salary-co-202610
          Income:Salary  -10000.00 CNY
          Assets:Receivable:Employer  940.00 CNY
          Assets:Bank

        2026-09-28 * "公司" "退回、报销" ^reimburse-co-20260928 ^salary-co-202610 ^salary-co-202609
          Assets:Receivable:Employer  1910.00 CNY
          Assets:Receivable:Employer  -940.00 CNY
          Assets:Receivable:Reimbursement  -100.00 CNY
          Assets:Bank

        """)
        let e = employerOpen(L)
        XCTAssertEqual(e.open.map { $0.link }, ["salary-co-202608", nil])
        XCTAssertFalse(e.open.contains { $0.link?.hasPrefix("reimburse") ?? false })
    }

    func testPettyCash() {
        // 备用金 on the reimbursement account; advances it covers carry its link; what is left goes back
        let L = ledger(base + """
        2026-09-01 * "公司" "备用金" ^float-co-20260901
          Assets:Receivable:Reimbursement  -1000.00 CNY
          Assets:Bank

        2026-09-02 * "店" "工具" #reimbursed ^float-co-20260901
          Assets:Receivable:Reimbursement  300.00 CNY
          Assets:Bank

        2026-09-03 * "店" "螺丝"
          Assets:Receivable:Reimbursement  20.00 CNY
          Assets:Bank

        2026-09-25 * "公司" "工资" ^salary-co-202609
          Income:Salary  -10000.00 CNY
          Assets:Bank

        """)
        let D = Derived(L, today: "2026-10-01")
        XCTAssertEqual(D.floats.map { $0.link }, ["float-co-20260901"])
        XCTAssertEqual(D.floats[0].received, 1000)
        XCTAssertEqual(D.floats[0].left, 700)
        XCTAssertEqual(D.unclaimed.map { $0.amount }, [20])     // only what petty cash did not cover
        XCTAssertFalse(employerOpen(L).open.contains { $0.link?.hasPrefix("float-") ?? false })
        XCTAssertEqual(linkFigures("float-co-20260901", D.byLink["float-co-20260901"]!, L).map { $0.value }, [1000, 300, 700])
        let issues = linkIssues(L, subscriptions: [])
        XCTAssertTrue(issues.isEmpty, issues.map { "\($0.kind) \($0.link ?? "")" }.joined(separator: ", "))
        // handing back the rest closes it
        let back = settleText(L, date: "2026-10-01", payee: "公司", narration: "退回备用金", link: "float-co-20260901",
                              items: [SettleItem(account: "Assets:Receivable:Reimbursement", currency: "CNY", amount: -700)], to: "Assets:Bank")
        let after = ledger(base + """
        2026-09-01 * "公司" "备用金" ^float-co-20260901
          Assets:Receivable:Reimbursement  -1000.00 CNY
          Assets:Bank

        2026-09-02 * "店" "工具" #reimbursed ^float-co-20260901
          Assets:Receivable:Reimbursement  300.00 CNY
          Assets:Bank

        """ + back + "\n")
        XCTAssertTrue(Derived(after, today: "2026-10-01").floats.isEmpty)
    }

    func testLoan() {
        let L = ledger(base)
        var d = LoanDraft()
        d.kind = .lend; d.name = "Rabi"; d.amount = "1000"; d.account = "Assets:Bank"; d.date = "2026-10-01"
        let t = loanText(d, L)
        // lending goes to the shared receivable with person:
        XCTAssertTrue(t.hasPrefix("2026-10-01 * \"Rabi\" \"借出\"\n  Assets:Receivable:Personal "), t)
        XCTAssertTrue(t.contains("\n    person: \"Rabi\"\n  Assets:Bank "), t)
        XCTAssertTrue(validateText(t, L).ok)
        XCTAssertTrue(validateText(t, L).warnings.isEmpty)
        // repaying goes to the loan account they already have
        d.kind = .repay; d.amount = "6000"
        let r = loanText(d, L)
        XCTAssertTrue(r.contains("Liabilities:Loan:Rabi") && !r.contains("open"), r)
        let after = ledger(base + r + "\n")
        XCTAssertTrue(people(after).first { $0.name == "Rabi" }!.settled)
        // borrowing from someone new opens their loan account, named
        d.kind = .borrow; d.name = "王五"; d.key = "WangWu"
        let b = loanText(d, L)
        XCTAssertTrue(b.hasPrefix("2026-10-01 open Liabilities:Loan:WangWu\n  name: \"王五\"\n\n"), b)
        XCTAssertEqual(people(ledger(base + b + "\n")).first { $0.name == "王五" }?.net["CNY"], -6000)
        d.key = "wangwu"
        XCTAssertEqual(loanText(d, L), "")
        XCTAssertEqual(accountPart(from: "wang wu"), "WangWu")
        XCTAssertEqual(accountPart(from: "王五"), "WangWu")
        XCTAssertEqual(accountPart(from: "五姨"), "WuYi")
        XCTAssertEqual(accountPart(from: "小 Li"), "XiaoLi")
        XCTAssertNil(accountPart(from: "😀"))
    }

    func testSettle() {
        let L = ledger(base)
        let t = settleText(L, date: "2026-10-01", payee: "公司", narration: "结清", link: "salary-co-202608",
                           items: [SettleItem(account: "Assets:Receivable:Employer", currency: "CNY", amount: -50)], to: "Income:Salary:Other")
        XCTAssertTrue(t.hasPrefix("2026-10-01 open Income:Salary:Other\n\n"), t)
        XCTAssertTrue(validateText(t, L, single: false).ok)
        let after = ledger(base + t + "\n")
        XCTAssertEqual(employerOpen(after).open.map { $0.link }, [nil])
    }

    func testSettlePerson() {
        let L = ledger(base)
        let wy = people(L).first { $0.name == "五姨" }!
        let items = wy.balances.keys.sorted().flatMap { a in wy.balances[a]!.map { SettleItem(account: a, currency: $0.key, amount: $0.value, person: wy.name) } }
        let t = settleText(L, date: "2026-10-01", payee: "五姨", narration: "结清", link: nil, items: items, to: "Equity:Opening")
        XCTAssertTrue(t.contains("person: \"五姨\""), t)
        XCTAssertTrue(people(ledger(base + t + "\n")).first { $0.name == "五姨" }!.settled)
    }

    func testAA() {
        let L = ledger(base)
        let D = Derived(L, today: "2026-10-01")
        var d = Draft()
        d.kind = .expense; d.date = "2026-10-01"; d.payee = "火锅"; d.account = "Expenses:Food"; d.funding = "Assets:Bank"
        d.amount = "300"; d.currency = "CNY"
        let each = evenShares(300, 2)
        XCTAssertEqual(each, [100, 100])
        XCTAssertEqual(evenShares(100, 2), [33.33, 33.33])
        d.split = true
        d.shares = [Share(person: "五姨", amount: "100"), Share(person: "王五", amount: "120")]
        let t = draftText(d, L, D)
        XCTAssertTrue(t.contains("Expenses:Food") && t.contains("80.00 CNY"), t)
        XCTAssertTrue(t.contains("person: \"王五\"") && t.contains("120.00 CNY"), t)
        XCTAssertTrue(t.contains("-300.00 CNY"), t)
        XCTAssertTrue(draftIsSingle(d, L))
        XCTAssertTrue(validateText(t, L).ok)
        let after = ledger(base + t + "\n")
        XCTAssertEqual(people(after).first { $0.name == "王五" }?.net["CNY"], 120)
        XCTAssertEqual(people(after).first { $0.name == "五姨" }?.net["CNY"], -2400)
        // more than the total: nothing to save
        d.shares[1].amount = "250"
        XCTAssertEqual(draftText(d, L, D), "")
        // a ledger without the personal receivable opens it with the first split
        let bare = ledger(base.replacingOccurrences(of: "2026-01-01 open Assets:Receivable:Personal\n", with: "").replacingOccurrences(of: "  Assets:Receivable:Personal  500.00 CNY\n    person: \"五姨\"\n", with: "  Expenses:Food  500.00 CNY\n"))
        d.shares[1].amount = "100"
        let n = draftText(d, bare, Derived(bare, today: "2026-10-01"))
        XCTAssertTrue(n.hasPrefix("2026-10-01 open Assets:Receivable:Personal\n  name: \"个人往来\"\n\n2026-10-01 * \"火锅\""), n)
        XCTAssertFalse(draftIsSingle(d, bare))
        XCTAssertTrue(validateText(n, bare, single: false).ok)
    }

    func testSomeonePaidForYou() {
        let L = ledger(base)
        let D = Derived(L, today: "2026-10-01")
        var d = Draft()
        d.kind = .expense; d.date = "2026-10-01"; d.payee = "饭店"; d.account = "Expenses:Food"
        d.funding = "Assets:Receivable:Personal"; d.person = "五姨"; d.amount = "60"; d.currency = "CNY"
        let t = draftText(d, L, D)
        XCTAssertTrue(t.contains("Assets:Receivable:Personal") && t.contains("person: \"五姨\""), t)
        let after = ledger(base + t + "\n")
        XCTAssertEqual(reviewChange(before: L, after: after).filter { $0.kind == .insufficient }, [])
        XCTAssertEqual(people(after).first { $0.name == "五姨" }?.balances["Assets:Receivable:Personal"]?["CNY"], 440)
        // the split form keeps who it is with
        let tx = after.txns.last!
        XCTAssertTrue(isComplex(tx))
        let m = draftFromTxn(tx, after, Derived(after, today: "2026-10-01"), defaultFunding: nil)
        XCTAssertEqual(m.rows.map { $0.person }, ["", "五姨"])
        XCTAssertTrue(draftText(m, after, Derived(after, today: "2026-10-01")).contains("person: \"五姨\""))
    }
}
