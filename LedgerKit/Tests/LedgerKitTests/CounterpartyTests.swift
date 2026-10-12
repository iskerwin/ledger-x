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
    2026-01-01 open Assets:Receivable:Personal:WuYi
      name: "五姨"
    2026-01-01 open Liabilities:Loan:WuYi
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
      Assets:Receivable:Personal:WuYi  500.00 CNY
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
        let ps = people(ledger(base))
        XCTAssertEqual(ps.map { $0.key }, ["Rabi", "WuYi", "Old"])
        let wy = ps[1]
        XCTAssertEqual(wy.name, "五姨")
        XCTAssertEqual(wy.net["CNY"], -2500)     // you paid 500 for her and borrowed 3000 from her
        XCTAssertEqual(wy.receivable, "Assets:Receivable:Personal:WuYi")
        XCTAssertEqual(wy.loan, "Liabilities:Loan:WuYi")
        XCTAssertTrue(ps[2].settled)
        XCTAssertEqual(ps[2].last, "2026-03-01")
        XCTAssertEqual(personEntries(ledger(base), "WuYi").count, 2)
        XCTAssertEqual(personKey("Liabilities:Loan:WuYi:Car"), "WuYi")
        XCTAssertNil(personKey("Assets:Receivable:Employer"))
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
        // 备用金 on the company account, later offset by a reimbursement
        let L = ledger(base + """
        2026-09-01 * "公司" "备用金" ^float-co-20260901
          Assets:Receivable:Employer  -1000.00 CNY
          Assets:Bank

        2026-09-02 * "店" "工具" #reimbursed ^reimburse-co-20260920
          Assets:Receivable:Reimbursement  300.00 CNY
          Assets:Bank

        2026-09-20 * "公司" "报销入账" #reimbursement ^reimburse-co-20260920 ^float-co-20260901
          Assets:Receivable:Reimbursement  -300.00 CNY
          Assets:Receivable:Employer  300.00 CNY

        2026-09-25 * "公司" "工资" ^salary-co-202609
          Income:Salary  -10000.00 CNY
          Assets:Bank

        """)
        let open = employerOpen(L).open
        XCTAssertEqual(open.first { $0.link == "float-co-20260901" }?.amount, -700)
        XCTAssertFalse(open.contains { $0.link == "salary-co-202609" })
        let issues = linkIssues(L, subscriptions: [])
        XCTAssertTrue(issues.isEmpty, issues.map { "\($0.kind) \($0.link ?? "")" }.joined(separator: ", "))
    }

    func testLoanOpensNewAccount() {
        let L = ledger(base)
        var d = LoanDraft()
        d.kind = .lend; d.key = "Rabi"; d.amount = "1000"; d.account = "Assets:Bank"; d.date = "2026-10-01"
        let t = loanText(d, L)
        // Rabi only had a loan account: lending opens his receivable
        XCTAssertTrue(t.hasPrefix("2026-10-01 open Assets:Receivable:Personal:Rabi\n\n2026-10-01 * \"Rabi\" \"借出\""), t)
        XCTAssertTrue(validateText(t, L, single: false).ok)
        d.kind = .repay; d.amount = "6000"
        let r = loanText(d, L)
        XCTAssertFalse(r.contains("open"))
        let after = ledger(base + r + "\n")
        XCTAssertTrue(people(after).first { $0.key == "Rabi" }!.settled)
        d.key = "rabi"
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
        d.shares = [Share(account: "Assets:Receivable:Personal:WuYi", amount: "100"), Share(account: "Assets:Receivable:Personal:Old", amount: "120")]
        let t = draftText(d, L, D)
        XCTAssertTrue(t.contains("Expenses:Food") && t.contains("80.00 CNY"), t)
        XCTAssertTrue(t.contains("Assets:Receivable:Personal:Old") && t.contains("120.00 CNY"), t)
        XCTAssertTrue(t.contains("-300.00 CNY"), t)
        XCTAssertTrue(validateText(t, L).ok)
        // more than the total: nothing to save
        d.shares[1].amount = "250"
        XCTAssertEqual(draftText(d, L, D), "")
        // someone new: their account is opened with the expense
        d.shares = [Share(account: "Assets:Receivable:Personal:WangWu", amount: "100", name: "王五"),
                    Share(account: "Assets:Receivable:Personal:Rabi", amount: "100", name: "Rabi")]
        let n = draftText(d, L, D)
        XCTAssertTrue(n.hasPrefix("2026-10-01 open Assets:Receivable:Personal:WangWu\n  name: \"王五\"\n\n2026-10-01 open Assets:Receivable:Personal:Rabi\n\n2026-10-01 * \"火锅\""), n)
        XCTAssertFalse(draftIsSingle(d, L))
        XCTAssertTrue(validateText(n, L, single: false).ok)
        let after = ledger(base + n + "\n")
        XCTAssertEqual(people(after).first { $0.key == "WangWu" }?.name, "王五")
        XCTAssertEqual(people(after).first { $0.key == "Rabi" }?.net["CNY"], -5900)
    }

    func testReceivableMayGoNegative() {
        let before = ledger(base)
        let after = ledger(base + """
        2026-10-01 * "Old" "他替我付"
          Expenses:Food  60.00 CNY
          Assets:Receivable:Personal:Old

        """)
        XCTAssertEqual(reviewChange(before: before, after: after).filter { $0.kind == .insufficient }, [])
    }
}
