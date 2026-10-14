import XCTest
@testable import LedgerKit

/// 币种与汇率: any two of 账单金额, 汇率, 换算金额 give the third, and the draft writes what was typed
final class RateTests: XCTestCase {
    private let base = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank:HSBC HKD
    2026-01-01 open Assets:Bank:BOC CNY
    2026-01-01 open Expenses:Shopping:Household

    """

    func testSolve() {
        XCTAssertEqual(solveRate(.converted, amount: 23, rate: 1.17912, converted: nil), 27.12)
        XCTAssertEqual(solveRate(.rate, amount: 23, rate: nil, converted: 27.12)!, 27.12 / 23, accuracy: 1e-9)
        XCTAssertEqual(solveRate(.amount, amount: nil, rate: 1.17912, converted: 27.12), 23)
        XCTAssertNil(solveRate(.rate, amount: 0, rate: nil, converted: 5))
        XCTAssertEqual(rateString(6.704080), "6.70408")
        XCTAssertEqual(rateString(7.8), "7.8")
        XCTAssertEqual(rateString(7), "7")
    }

    func testWritesWhatWasTyped() {
        let L = loadLedger(root: "main.bean") { _ in self.base }
        let D = Derived(L, today: "2026-10-14")
        var d = Draft()
        d.kind = .expense; d.date = "2026-10-14"; d.payee = "丽娜超市"; d.narration = "日用品"
        d.account = "Expenses:Shopping:Household"; d.funding = "Assets:Bank:HSBC"; d.currency = "CNY"

        // amount and rate typed: the rate as it is
        setConversion(&d, amount: "23", rate: "1.17912", converted: "27.12", computed: .converted)
        var t = draftText(d, L, D)
        XCTAssertTrue(t.contains("23.00 CNY @ 1.17912 HKD") && t.contains("-27.12 HKD"), t)
        XCTAssertEqual(draftRate(d)!, 1.17912, accuracy: 1e-9)

        // amount and the amount charged typed: the charge
        setConversion(&d, amount: "23", rate: "1.17913", converted: "27.12", computed: .rate)
        t = draftText(d, L, D)
        XCTAssertFalse(d.byRate)
        XCTAssertTrue(t.contains("-27.12 HKD") && t.contains("CNY @"), t)
        XCTAssertTrue(validateText(t, L).ok, validateText(t, L).msg ?? "")
        XCTAssertEqual(draftRate(d)!, 27.12 / 23, accuracy: 1e-9)
    }
}
