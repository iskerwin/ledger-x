import XCTest
@testable import LedgerKit

/// 完成 tapped before the card is complete: the message says what is missing, never nothing.
final class DraftMissingTests: XCTestCase {
    lazy var L = loadSet("realistic")
    lazy var D = Derived(L, today: TODAY)

    func missing(_ d: Draft) -> String? { draftMissing(d, L, D) }

    func testCursorJumpsOnceAndDoesNotOverrideALaterChoice() {
        XCTAssertEqual(DraftCursor(.amount), .amount)
        XCTAssertEqual(DraftCursor(.toAmount), .toAmount)
        XCTAssertEqual(DraftCursor(.rate), .rate)
        XCTAssertEqual(DraftCursor(.paid), .paid)
        XCTAssertNil(DraftCursor(.category))
        XCTAssertNil(DraftCursor(.funding))
        XCTAssertNil(DraftCursor(.date))
        // the first request moves to the invalid field, even if another text field was focused
        XCTAssertEqual(cursorPlacement(target: .amount, current: nil, kept: false, attempt: 0), .amount)
        XCTAssertEqual(cursorPlacement(target: .amount, current: .paid, kept: false, attempt: 0), .amount)
        XCTAssertEqual(cursorPlacement(target: .paid, current: nil, kept: true, attempt: 0), .paid)
        // the form dropped the cursor while scrolling: ask once more
        XCTAssertEqual(cursorPlacement(target: .amount, current: nil, kept: false, attempt: 1), .amount)
        // it already landed, the user moved to another field, or we have tried enough
        XCTAssertNil(cursorPlacement(target: .amount, current: .amount, kept: false, attempt: 1))
        XCTAssertNil(cursorPlacement(target: .amount, current: .rate, kept: false, attempt: 1))
        XCTAssertNil(cursorPlacement(target: .amount, current: nil, kept: true, attempt: 1))
        XCTAssertNil(cursorPlacement(target: .amount, current: nil, kept: false, attempt: 2))
        XCTAssertNil(cursorPlacement(target: nil, current: nil, kept: false, attempt: 0))
    }

    func testIssueTargetsIdentifyTheNextField() {
        var d = Draft()
        XCTAssertEqual(draftIssue(d, L, D)?.field, .amount)
        d.amount = "12"
        XCTAssertEqual(draftIssue(d, L, D)?.field, .category)
        d.account = "Expenses:Food:Drinks"
        XCTAssertEqual(draftIssue(d, L, D)?.field, .funding)
        d.funding = "Assets:Bank:BOCHK"
        XCTAssertEqual(draftIssue(d, L, D)?.field, .paid)
        d.byRate = true
        XCTAssertEqual(draftIssue(d, L, D)?.field, .rate)
        d.rate = "1.08"
        XCTAssertNil(draftIssue(d, L, D))
    }

    func testSameAccountTransferRequiresDifferentCurrency() {
        var d = Draft(); d.kind = .transfer; d.amount = "12"
        d.funding = "Assets:Bank:CGB"; d.to = d.funding
        XCTAssertEqual(draftIssue(d, L, D)?.field, .toAmount)
        d.to = "Assets:Bank:BOCHK"
        XCTAssertEqual(draftIssue(d, L, D)?.field, .toAmount)
    }

    func testExpense() {
        var d = Draft(); d.currency = "CNY"
        d.kind = .expense
        XCTAssertEqual(missing(d), tr("请输入金额", "Enter an amount"))
        d.amount = "0"
        XCTAssertEqual(missing(d), tr("金额要大于 0", "The amount must be more than 0"))
        d.amount = "30"
        XCTAssertEqual(missing(d), tr("请选择支出科目", "Choose an expense category"))
        d.account = "Expenses:Food:Drinks"
        d.funding = ""
        XCTAssertEqual(missing(d), tr("请选择付款账户", "Choose the paying account"))
        d.funding = "Assets:Bank:CGB"
        XCTAssertNil(missing(d))
        XCTAssertFalse(draftText(d, L, D).isEmpty, "complete exactly when the text can be made")
    }

    func testIncomeRefundTransfer() {
        var d = Draft(); d.currency = "CNY"
        d.kind = .income; d.amount = "100"
        XCTAssertEqual(missing(d), tr("请选择收入科目", "Choose an income category"))
        d.account = "Income:Salary:Work"; d.funding = ""
        XCTAssertEqual(missing(d), tr("请选择收款账户", "Choose the receiving account"))
        d.kind = .refund; d.account = "Expenses:Food:Drinks"
        XCTAssertEqual(missing(d), tr("请选择退回的账户", "Choose the account refunded to"))
        var t = Draft(); t.currency = "CNY"
        t.kind = .transfer; t.amount = "50"; t.funding = ""
        XCTAssertEqual(missing(t), tr("请选择转出账户", "Choose the account to transfer from"))
        t.funding = "Assets:Bank:CGB"
        XCTAssertEqual(missing(t), tr("请选择转入账户", "Choose the account to transfer to"))
    }

    func testSplitAndCombo() {
        var d = Draft(); d.currency = "CNY"
        d.kind = .expense; d.amount = "100"; d.account = "Expenses:Food:Drinks"; d.funding = "Assets:Bank:CGB"; d.currency = "CNY"
        d.split = true
        d.shares = [Share(person: "", amount: "50")]
        XCTAssertEqual(missing(d), tr("AA 分摊：每一位都要填名字和金额", "Split: give each person a name and an amount"))
        d.shares = [Share(person: "王五", amount: "150")]
        XCTAssertEqual(missing(d), tr("AA 分摊的金额加起来超过了总额", "The split parts add up to more than the total"))
        d.split = false; d.shares = []
        d.discount = "120"; d.discountAccount = "Income:Rewards"
        XCTAssertEqual(missing(d), tr("优惠金额要小于总额", "The discount must be less than the total"))
    }

    func testAccountInAnotherCurrencyNeedsTheRate() {
        // BOCHK holds HKD only: a CNY bill paid from it needs the rate or the amount charged
        XCTAssertNil(L.final["Assets:Bank:BOCHK"]?["CNY"])
        var d = Draft(); d.currency = "CNY"
        d.kind = .expense; d.amount = "100"; d.account = "Expenses:Food:Drinks"; d.funding = "Assets:Bank:BOCHK"
        XCTAssertEqual(missing(d), tr("付款账户是 HKD，请填写汇率或扣款金额", "The paying account is in HKD: fill in the rate or the amount charged"))
        XCTAssertTrue(draftText(d, L, D).isEmpty, "not written as CNY into an HKD account")
        d.byRate = true; d.rate = "1.08"
        XCTAssertNil(missing(d))
        XCTAssertTrue(draftText(d, L, D).contains("100.00 CNY @ 1.08 HKD"))
        d.byRate = false; d.rate = ""; d.paid = "108.50"
        XCTAssertNil(missing(d))
        XCTAssertTrue(draftText(d, L, D).contains("-108.50 HKD"))
        // income into it likewise
        var i = Draft(); i.currency = "CNY"
        i.kind = .income; i.amount = "100"; i.account = "Income:Salary:Work"; i.funding = "Assets:Bank:BOCHK"
        XCTAssertEqual(missing(i), tr("收款账户是 HKD，请填写汇率或入账金额", "The receiving account is in HKD: fill in the rate or the amount received"))
        // a transfer into it needs the amount received
        var t = Draft(); t.currency = "CNY"
        t.kind = .transfer; t.amount = "100"; t.funding = "Assets:Bank:CGB"; t.to = "Assets:Bank:BOCHK"
        XCTAssertEqual(missing(t), tr("转入账户是 HKD，请填写入账金额", "The receiving account is in HKD: fill in the amount received"))
        XCTAssertTrue(draftText(t, L, D).isEmpty)
        t.toAmount = "108"
        XCTAssertNil(missing(t))
        XCTAssertFalse(draftText(t, L, D).isEmpty)
    }

    func testEveryIncompleteFormSaysSomething() {
        // whatever is left out, the text being empty and a message being there go together
        let kinds: [DraftKind] = [.expense, .income, .refund, .transfer]
        for k in kinds {
            for amount in ["", "12"] {
                for account in ["", "Expenses:Food:Drinks"] {
                    for funding in ["", "Assets:Bank:CGB"] {
                        var d = Draft(); d.currency = "CNY"
                        d.kind = k; d.amount = amount; d.account = account; d.funding = funding
                        if k == .transfer { d.to = account.isEmpty ? "" : "Assets:EWallet:Alipay" }
                        if k == .income && !account.isEmpty { d.account = "Income:Salary:Work" }
                        let text = draftText(d, L, D)
                        XCTAssertEqual(text.isEmpty, missing(d) != nil, "\(k) \(amount) \(account) \(funding)")
                    }
                }
            }
        }
    }
}

