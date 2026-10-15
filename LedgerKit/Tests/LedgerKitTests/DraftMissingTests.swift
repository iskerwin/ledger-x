import XCTest
@testable import LedgerKit

/// 完成 tapped before the card is complete: the message says what is missing, never nothing.
final class DraftMissingTests: XCTestCase {
    lazy var L = loadSet("realistic")
    lazy var D = Derived(L, today: TODAY)

    func missing(_ d: Draft) -> String? { draftMissing(d, L, D) }

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
