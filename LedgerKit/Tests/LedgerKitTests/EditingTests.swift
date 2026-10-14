import XCTest
@testable import LedgerKit

/// 可视化编辑: an entry opens in the form only when the form writes it back unchanged
final class EditingTests: XCTestCase {
    private let base = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank:BOC CNY
    2026-01-01 open Assets:Bank:HSBC HKD
    2026-01-01 open Assets:Bank:HSBC:USD USD
    2026-01-01 open Assets:EWallet:WeChatPay CNY
    2026-01-01 open Assets:Receivable:Reimbursement
    2026-01-01 open Liabilities:CreditCard:CMB CNY
    2026-01-01 open Expenses:Food:Dining
    2026-01-01 open Expenses:Shopping:Household
    2026-01-01 open Expenses:Digital
    2026-01-01 open Assets:Invest:Stock VOO
    2026-01-01 open Income:Rewards
    2026-01-01 open Income:Salary
    2026-08-25 custom "event" "trip-zz" "郑州出差"

    """
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    /// the form for the last entry of `tx`, and that entry
    private func open(_ tx: String) -> (Draft?, Entry, Ledger, Derived) {
        let L = ledger(base + tx + "\n")
        let D = Derived(L, today: "2026-10-14")
        let e = L.txns.last!
        return (editDraft(e, L, D), e, L, D)
    }

    /// the form's text, read back, is the same entry
    private func assertRoundTrip(_ tx: String, kind: DraftKind? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let (d, e, L, D) = open(tx)
        guard let d = d else { return XCTFail("not editable:\n\(tx)", file: file, line: line) }
        if let k = kind { XCTAssertEqual(d.kind, k, file: file, line: line) }
        let back = checkText(draftText(d, L, D), L).entries.first { $0.type == .txn }
        XCTAssertNotNil(back, file: file, line: line)
        if let b = back { XCTAssertTrue(sameTxn(e, b), draftText(d, L, D), file: file, line: line) }
    }

    func testSimple() {
        assertRoundTrip("""
        2026-10-12 * "饭店" "午饭" #trip-zz #work ^doc-x
          note: "发票已开"
          Expenses:Food:Dining                                35.00 CNY
          Assets:EWallet:WeChatPay                           -35.00 CNY
        """, kind: .expense)
        assertRoundTrip("""
        2026-10-12 * "公司" "奖金"
          Assets:Bank:BOC                                   500.00 CNY
          Income:Salary                                    -500.00 CNY
        """, kind: .income)
        // flagged: the split form, which shows the flag
        assertRoundTrip("""
        2026-10-12 ! "公司" "奖金"
          Assets:Bank:BOC                                   500.00 CNY
          Income:Salary                                    -500.00 CNY
        """, kind: .multi)
    }

    func testComboAndRate() {
        assertRoundTrip("""
        2026-10-13 * "超市" "日用品"
          Expenses:Shopping:Household                        100.00 CNY
          Assets:EWallet:WeChatPay                           -50.00 CNY
          Liabilities:CreditCard:CMB                         -40.00 CNY
          Income:Rewards                                     -10.00 CNY
        """, kind: .expense)
        // a price as on the receipt
        let tx = """
        2026-10-14 * "丽娜超市" "日用品"
          Expenses:Shopping:Household                         23.00 CNY @ 1.17912 HKD
          Assets:Bank:HSBC                                   -27.12 HKD
        """
        assertRoundTrip(tx, kind: .expense)
        XCTAssertEqual(open(tx).0?.byRate, true)
    }

    func testReimbursedAndSubscription() {
        assertRoundTrip("""
        2026-09-01 * "五金店" "辅材" #reimbursed ^float-chailu-20260831
          Assets:Receivable:Reimbursement                    154.00 CNY
          Assets:EWallet:WeChatPay                          -154.00 CNY
        """)
        assertRoundTrip("""
        2026-10-01 * "Apple" "iCloud+" ^sub-apple-icloud
          topup: TRUE
          Expenses:Digital                                     6.00 CNY
          Assets:Bank:BOC                                     -6.00 CNY
        """)
    }

    func testTransferAndExchange() {
        assertRoundTrip("""
        2026-10-02 * "Transfer" "BOC -> CMB" #transfer
          Liabilities:CreditCard:CMB                        1000.00 CNY
          Assets:Bank:BOC                                  -1000.00 CNY
        """, kind: .transfer)
        let fx = """
        2026-10-03 * "HSBC" "HKD -> USD" #fx
          exchange_rate: "1 USD = 7.80000 HKD"
          Assets:Bank:HSBC:USD                               100.00 USD @@ 780.00 HKD
          Assets:Bank:HSBC                                  -780.00 HKD
        """
        assertRoundTrip(fx, kind: .transfer)
        // other amounts: the rate worked out again, quoted the bank's way round
        let (d0, _, L, D) = open(fx)
        var d = try! XCTUnwrap(d0)
        d.toAmount = "101"
        XCTAssertTrue(draftText(d, L, D).contains("exchange_rate: \"1 USD = 7.72277 HKD\""), draftText(d, L, D))
    }

    func testMulti() {
        assertRoundTrip("""
        2026-10-04 * "饭店" "聚餐"
          Expenses:Food:Dining                                60.00 CNY
          Expenses:Shopping:Household                         40.00 CNY
          Assets:Bank:BOC                                    -30.00 CNY
          Assets:EWallet:WeChatPay                           -70.00 CNY
        """)
    }

    func testNotEditable() {
        // a comment would be lost
        XCTAssertNil(open("""
        2026-10-05 * "饭店" "午饭"   ; 和同事
          Expenses:Food:Dining                                35.00 CNY
          Assets:EWallet:WeChatPay                           -35.00 CNY
        """).0)
        // a lot at cost: the split form keeps it
        assertRoundTrip("""
        2026-10-06 * "券商" "买入"
          Assets:Invest:Stock                                  1 VOO {3500.00 CNY}
          Assets:Bank:BOC                                  -3500.00 CNY
        """, kind: .multi)
    }

    func testChangeKeepsTheRest() {
        let (d0, _, L, D) = open("""
        2026-10-12 * "饭店" "午饭" #work ^doc-x
          note: "发票已开"
          Expenses:Food:Dining                                35.00 CNY
          Assets:EWallet:WeChatPay                           -35.00 CNY
        """)
        var d = try! XCTUnwrap(d0)
        d.amount = "38"
        let t = draftText(d, L, D)
        XCTAssertTrue(t.contains("38.00 CNY") && t.contains("#work") && t.contains("^doc-x") && t.contains("note: \"发票已开\""), t)
        XCTAssertTrue(validateText(t, L).ok, validateText(t, L).msg ?? "")
    }

    func testSameTxn() {
        let L = ledger(base + """
        2026-10-12 * "饭店" "午饭"
          Expenses:Food:Dining                                35.00 CNY
          Assets:EWallet:WeChatPay                           -35.00 CNY

        2026-10-12 * "饭店" "午饭"
          Assets:EWallet:WeChatPay   -35 CNY
          Expenses:Food:Dining

        2026-10-12 * "饭店" "午饭"
          Expenses:Food:Dining                                36.00 CNY
          Assets:EWallet:WeChatPay                           -36.00 CNY

        """)
        let t = L.txns.suffix(3).map { $0 }
        XCTAssertTrue(sameTxn(t[0], t[1]))
        XCTAssertFalse(sameTxn(t[0], t[2]))
    }
}
