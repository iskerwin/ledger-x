import XCTest
@testable import LedgerKit

/// link checks between refunds, reimbursements and subscriptions
final class LinkTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private let base = """
    option "operating_currency" "CNY"
    2023-01-01 open Assets:Bank CNY
    2023-01-01 open Assets:Receivable:Reimbursement CNY
    2023-01-01 open Expenses:Food CNY
    2023-01-01 open Expenses:Shopping CNY
    2023-01-01 open Expenses:Subscription CNY

    """

    private func kinds(_ L: Ledger) -> [String: [LinkIssue.Kind]] {
        var m: [String: [LinkIssue.Kind]] = [:]
        for i in linkIssues(L, subscriptions: subscriptions(L)) { m[i.link ?? i.txn.date, default: []].append(i.kind) }
        return m
    }

    func testRefunds() {
        let L = ledger(base + """
        2025-01-01 * "Shop" "Shoes" ^refund-a
          Expenses:Shopping  100 CNY
          Assets:Bank
        2025-01-05 * "Shop" "Shoes refund" #refund ^refund-a
          Expenses:Shopping  -120 CNY
          Assets:Bank
        2025-02-01 * "Shop" "lonely refund" #refund ^refund-b
          Expenses:Shopping  -10 CNY
          Assets:Bank
        2025-03-01 * "Cafe" "wrong account" ^refund-c
          Expenses:Food  30 CNY
          Assets:Bank
        2025-03-02 * "Cafe" "refund" #refund ^refund-c
          Expenses:Shopping  -30 CNY
          Assets:Bank
        2025-03-03 * "Cafe" "untied refund" #refund
          Expenses:Food  -5 CNY
          Assets:Bank

        """)
        let k = kinds(L)
        XCTAssertEqual(k["refund-a"], [.refundExceeds])
        XCTAssertEqual(k["refund-b"], [.refundAlone])
        XCTAssertEqual(k["refund-c"], [.refundAccount])
        XCTAssertEqual(k["2025-03-03"], [.refundUnlinked])
        let figs = linkFigures("refund-a", L.txns.filter { $0.links.contains("refund-a") }, L)
        XCTAssertEqual(figs.map { $0.value }, [100, 120, -20])
    }

    func testReimbursementSubscriptionsAndOthers() {
        let L = ledger(base + """
        2025-01-01 custom "subscription" "iCloud+" "monthly" 21.00 CNY
          account: "Expenses:Subscription"
          link: "sub-icloud"
        2025-01-02 * "Hotel" "trip" #reimbursed ^reimburse-x
          Assets:Receivable:Reimbursement  500 CNY
          Assets:Bank
        2025-01-20 * "Company" "pay back" #reimbursement ^reimburse-x
          Assets:Receivable:Reimbursement  -450 CNY
          Assets:Bank
        2025-01-21 * "Company" "pay back" #reimbursement ^reimburse-y
          Assets:Receivable:Reimbursement  -50 CNY
          Assets:Bank
        2025-02-01 * "Apple" "iCloud" ^sub-icloud
          Expenses:Food  21 CNY
          Assets:Bank
        2025-02-02 * "Netflix" "" ^sub-netflix
          Expenses:Subscription  60 CNY
          Assets:Bank
        2025-02-03 * "Trip" "" ^trip-2025
          Expenses:Food  60 CNY
          Assets:Bank
        2025-02-04 * "Trip" "" ^trip-2025
          Expenses:Food  60 CNY
          Assets:Bank
        2025-02-05 * "Typo" "" ^trip-2052
          Expenses:Food  6 CNY
          Assets:Bank

        """)
        let k = kinds(L)
        XCTAssertEqual(k["reimburse-x"], [.reimburseUnbalanced])
        XCTAssertEqual(k["reimburse-y"], [.reimburseNoAdvance])
        XCTAssertEqual(k["sub-icloud"], [.subAccount])
        XCTAssertEqual(k["sub-netflix"], [.subUnknown])
        XCTAssertNil(k["trip-2025"])
        XCTAssertEqual(k["trip-2052"], [.single])
        // errors come first
        let all = linkIssues(L, subscriptions: subscriptions(L))
        XCTAssertTrue(all.prefix(2).allSatisfy { $0.isError })
    }

    func testRefundsOfIncomeLoansAndAdvances() {
        let L = ledger(base + """
        2023-01-01 open Income:Salary CNY
        2023-01-01 open Liabilities:Loan:Mom CNY
        2023-01-01 open Assets:EWallet CNY
        2025-04-16 * "Boss" "salary advance" ^refund-salary-20250416
          Income:Salary  -500 CNY
          Assets:Bank
        2025-04-17 * "Boss" "advance returned" #refund ^refund-salary-20250416
          Income:Salary  500 CNY
          Assets:EWallet
        2025-07-04 * "Mom" "repayment" ^refund-loan-20250704
          Liabilities:Loan:Mom  1000 CNY
          Assets:Bank
        2025-07-05 * "Mom" "repayment back" #refund ^refund-loan-20250704
          Liabilities:Loan:Mom  -1000 CNY
          Assets:Bank
        2025-08-01 * "Taxi" "" #reimbursed ^refund-taxi-20250801
          Assets:Receivable:Reimbursement  54.57 CNY
          Assets:Bank
        2025-08-01 * "Taxi" "refund" #refund #reimbursed ^refund-taxi-20250801
          Assets:Receivable:Reimbursement  -8.23 CNY
          Assets:EWallet
        2025-09-01 * "Taxi" "" ^refund-taxi-20250901
          Expenses:Food  39.81 CNY
          Assets:Bank
        2025-09-01 * "Taxi" "refund" #refund ^refund-taxi-20250901
          Expenses:Food  -39.81 CNY
          Assets:EWallet

        """)
        XCTAssertTrue(linkIssues(L, subscriptions: []).isEmpty, "\(linkIssues(L, subscriptions: []).map { $0.kind })")
        let figs = linkFigures("refund-taxi-20250801", L.txns.filter { $0.links.contains("refund-taxi-20250801") }, L)
        XCTAssertEqual(figs.map { $0.value }, [54.57, 8.23, 46.34])
    }

    func testRefundLinkName() {
        let L = ledger(base + """
        2025-09-02 * "优衣库" "羽绒服"
          Expenses:Shopping  1 CNY
          Assets:Bank
        2025-09-03 * "Apple Store" ""
          Expenses:Shopping  1 CNY
          Assets:Bank
        2025-09-04 * "" "!!"
          Expenses:Shopping  1 CNY
          Assets:Bank

        """)
        XCTAssertEqual(newRefundLink(L.txns[0]), "refund-youyiku-20250902")
        XCTAssertEqual(newRefundLink(L.txns[0], taken: ["refund-youyiku-20250902", "refund-youyiku-20250902-2"]), "refund-youyiku-20250902-3")
        XCTAssertEqual(newRefundLink(L.txns[1]), "refund-apple-store-20250903")
        XCTAssertEqual(newRefundLink(L.txns[2]), "refund-20250904")
        XCTAssertTrue(isValidLink("refund-youyiku-20250902"))
        XCTAssertFalse(isValidLink("退款-1"))
        XCTAssertFalse(isValidLink("a b"))
    }

    func testHeaderLinkEdit() {
        let t = "2025-01-01 * \"A ;b\" \"c\" ; note\n  Expenses:Food  1 CNY\n  Assets:Bank"
        let added = headerLinkEdit(t, link: "refund-x", remove: false)
        XCTAssertTrue(added.hasPrefix("2025-01-01 * \"A ;b\" \"c\" ^refund-x ; note\n"))
        XCTAssertEqual(headerLinkEdit(added, link: "refund-x", remove: false), added)
        XCTAssertEqual(headerLinkEdit(added, link: "refund-x", remove: true).components(separatedBy: "\n")[0], "2025-01-01 * \"A ;b\" \"c\" ; note")
    }
}
