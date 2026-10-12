import XCTest
@testable import LedgerKit

/// salary by payslip
final class SalaryTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private let base = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank:BOC CNY
    2026-01-01 open Assets:Receivable:Employer
    2026-01-01 open Income:Salary:Base CNY
    2026-01-01 open Income:Salary:Bonus CNY
    2026-01-01 open Equity:Opening

    2026-09-09 * "柴鹿" "2026-07 工资" ^salary-chailu-202607
      payslip_days: 22
      Income:Salary:Base  -5000.00 CNY
      Assets:Bank:BOC  5000.00 CNY

    """

    func testPayslip() {
        let L = ledger(base)
        let t = PayslipTemplate(employer: "柴鹿", account: "Assets:Bank:BOC")
        XCTAssertEqual(t.linkSlug, "chailu")
        var d = payslipDraft(L, template: t, month: "2026-08", date: "2026-09-24")
        XCTAssertEqual(d.values["基本工资"], "5000.00")      // from July's payslip
        XCTAssertEqual(d.days, "22")
        d.values["绩效工资"] = "2000"
        d.values["请假扣除工资"] = "60"
        d.values["其他扣除"] = "40"
        XCTAssertEqual(d.gross, 7000)
        XCTAssertEqual(d.net, 6900)
        d.received = "4960"
        XCTAssertEqual(d.pending, 1940)
        let text = payslipText(d, L)
        // the accounts the ledger lacks are opened, both deductions go to one posting
        XCTAssertTrue(text.contains("open Income:Salary:Performance"), text)
        XCTAssertTrue(text.contains("open Income:Salary:Deduction"), text)
        XCTAssertFalse(text.contains("IncomeTax"), text)
        XCTAssertTrue(text.contains("2026-09-24 * \"柴鹿\" \"2026-08 工资\" ^salary-chailu-202608"), text)
        XCTAssertTrue(validateText(text, L, single: false).ok, text)
        let after = ledger(base + text + "\n")
        let tx = after.txns.last!
        XCTAssertEqual(tx.postings.first { $0.account == "Income:Salary:Deduction" }?.units, 100)
        XCTAssertEqual(tx.postings.first { $0.account == "Assets:Receivable:Employer" }?.units, 1940)
        XCTAssertEqual(employerOpen(after).open.map { $0.link }, ["salary-chailu-202608"])

        let y = salaryYears(after)[0]
        XCTAssertEqual(y.year, "2026")
        XCTAssertEqual(y.gross, 12000)
        XCTAssertEqual(y.deductions, 100)
        XCTAssertEqual(y.months, 1)   // both paid in September

        // items sharing an account are listed, and come back next month
        var t2 = t
        t2.items.insert(PayslipItem(name: "餐补", account: "Income:Salary:Allowance"), at: 2)
        t2.items.insert(PayslipItem(name: "交通补贴", account: "Income:Salary:Allowance"), at: 3)
        var a = PayslipDraft(template: t2, month: "2026-09", date: "2026-10-24")
        a.account = "Assets:Bank:BOC"
        a.values = ["基本工资": "2080", "餐补": "400", "交通补贴": "400"]
        a.received = "2080"
        let at = payslipText(a, after)
        XCTAssertTrue(at.contains("payslip_items: \"基本工资 2080.00; 餐补 400.00; 交通补贴 400.00\""), at)
        let after2 = ledger(base + text + "\n\n" + at + "\n")
        let next = payslipDraft(after2, template: t2, month: "2026-10", date: "2026-11-24")
        XCTAssertEqual(next.values["餐补"], "400.00")
        XCTAssertEqual(next.values["交通补贴"], "400.00")
        XCTAssertEqual(employerOpen(after2).open.first { $0.link == "salary-chailu-202609" }?.amount, 800)

        // usual amounts in the template come before last month's
        var t3 = t2
        t3.items[0].amount = 2600
        t3.items[2].amount = 500
        let std = payslipDraft(after2, template: t3, month: "2026-10", date: "2026-11-24")
        XCTAssertEqual(std.values["基本工资"], "2600.00")
        XCTAssertEqual(std.values["餐补"], "500.00")
        XCTAssertNil(std.values["交通补贴"])

        // nothing earned: nothing to save
        XCTAssertEqual(payslipText(PayslipDraft(template: t, month: "2026-08", date: "2026-09-24"), L), "")
    }

    func testTemplatesInConfig() {
        var c = LedgerXConfig()
        XCTAssertFalse(c.json().contains("payslips"))
        c.payslips = [PayslipTemplate(employer: "柴鹿", account: "Assets:Bank:BOC")]
        let back = LedgerXConfig.parse(c.json())
        XCTAssertEqual(back?.payslips?.first?.items.count, PayslipTemplate.defaultItems.count)
        XCTAssertEqual(back?.payslips?.first?.items.last?.deduct, true)
    }
}
