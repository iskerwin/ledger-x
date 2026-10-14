import XCTest
@testable import LedgerKit

/// 截图记账: real screenshots' recognised text (Fixtures/scan), read as payments and turned into drafts
final class ScanParseTests: XCTestCase {
    private func sample(_ name: String) -> ScanFields {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("scan/\(name).txt")
        return parseScan(try! String(contentsOf: url, encoding: .utf8))
    }

    func testWeChatDetails() {
        var f = sample("wechat-detail-en-1")
        XCTAssertEqual(f.source, .wechat)
        XCTAssertEqual(f.kind, .payment)
        XCTAssertEqual(f.amount, 4.00); XCTAssertEqual(f.currency, "CNY")
        XCTAssertEqual(f.payee, "金牌烧鹅示例店")
        XCTAssertEqual(f.date, "2026-10-13"); XCTAssertEqual(f.time, "12:21:13")
        XCTAssertEqual(f.method, "BOC Depit Card （4321）"); XCTAssertEqual(f.last4, "4321")
        XCTAssertEqual(f.orderNo, "4200000001202610130000000011")
        XCTAssertNil(f.note)

        f = sample("wechat-detail-en-2")
        XCTAssertEqual(f.amount, 7.20)
        XCTAssertEqual(f.payee, "喜市多")
        XCTAssertEqual(f.payeeFull, "广州喜市多便利连锁有限公司")
        XCTAssertEqual(f.date, "2026-10-13"); XCTAssertEqual(f.last4, "4321")
    }

    func testWeChatForeignCard() {
        var f = sample("wechat-detail-fx-1")
        XCTAssertEqual(f.amount, 90.23); XCTAssertEqual(f.currency, "CNY")
        XCTAssertEqual(f.charged, 106.45); XCTAssertEqual(f.chargedCurrency, "HKD")
        XCTAssertEqual(f.rate, "1.17972"); XCTAssertEqual(f.rateBase, "CNY"); XCTAssertEqual(f.rateQuote, "HKD")
        XCTAssertEqual(f.payee, "高德打车")
        XCTAssertEqual(f.note, "高德打车订单")
        XCTAssertEqual(f.date, "2026-09-30")
        XCTAssertEqual(f.last4, "2468")
        XCTAssertEqual(f.orderNo, "4500000001202609300000000044")

        f = sample("wechat-detail-fx-2")
        XCTAssertEqual(f.payee, "丽娜超市")
        XCTAssertEqual(f.amount, 4.00); XCTAssertEqual(f.charged, 4.71); XCTAssertEqual(f.rate, "1.17828")
        XCTAssertEqual(f.orderNo, "4200000001202609290000000033")
    }

    func testWeChatChinese() {
        var f = sample("wechat-qr-transfer-zh-1")
        XCTAssertEqual(f.amount, 350)
        XCTAssertEqual(f.payee, "明亮眼镜店")
        XCTAssertEqual(f.method, "零钱通"); XCTAssertNil(f.last4)
        XCTAssertEqual(f.date, "2024-10-15")
        XCTAssertEqual(f.orderNo, "10000000012024101500000000000055")

        f = sample("wechat-success-zh-1")
        XCTAssertEqual(f.amount, 6200)
        XCTAssertEqual(f.payee, "广东财政")
        XCTAssertNil(f.date)
        XCTAssertNil(f.method)
    }

    func testSeveralOnOneScreen() {
        XCTAssertEqual(sample("wechat-pay-notices-en-1").kind, .several(2))
    }

    func testAlipay() {
        var f = sample("alipay-detail-zh-1")
        XCTAssertEqual(f.source, .alipay)
        XCTAssertEqual(f.amount, 2.00)
        XCTAssertEqual(f.payee, "广东岭南通股份有限公司")
        XCTAssertEqual(f.date, "2026-10-12")
        XCTAssertEqual(f.last4, "4321")
        XCTAssertEqual(f.note, "随用随充充值")
        XCTAssertEqual(f.category, "充值缴费")

        f = sample("alipay-detail-etc-1")
        XCTAssertEqual(f.amount, 0.85)
        XCTAssertEqual(f.date, "2026-10-10"); XCTAssertEqual(f.time, "22:48:00")
        XCTAssertEqual(f.note, "东城站 → 西湖站")

        f = sample("alipay-taobao-zh-1")
        XCTAssertEqual(f.platform, "淘宝")
        XCTAssertEqual(f.amount, 79.20)
        XCTAssertEqual(f.note, "适用iwatch12表带野径回环apple")
        XCTAssertEqual(f.category, "服饰装扮")

        f = sample("alipay-transfer-zh-1")
        XCTAssertEqual(f.kind, .transfer)
        XCTAssertEqual(f.payee, "好心人")
        XCTAssertNil(f.note)

        f = sample("alipay-visa-discount-zh-1")
        XCTAssertEqual(f.amount, 194.14)
        XCTAssertEqual(f.listPrice, 195.00)
        XCTAssertEqual(f.discount, 0.86)
        XCTAssertEqual(f.last4, "2468")
        XCTAssertEqual(f.payee, "辣椒小厨总部")
    }

    func testAlipayRefunds() {
        var f = sample("alipay-refund-zh-1")
        XCTAssertEqual(f.kind, .refund)
        XCTAssertEqual(f.amount, 9.90)
        XCTAssertEqual(f.payee, "宝贝**店"); XCTAssertTrue(f.masked)
        XCTAssertEqual(f.date, "2026-10-10")
        XCTAssertEqual(f.last4, "4321")

        f = sample("alipay-refund-zh-2")
        XCTAssertEqual(f.kind, .refund)
        XCTAssertEqual(f.amount, 43)
        XCTAssertEqual(f.method, "浦发银行信用卡（8765）")
    }

    // MARK: - drafts

    private let ledgerText = """
    option "operating_currency" "CNY"
    2020-01-01 open Assets:Bank:BOC CNY
      name: "中国银行 4321"
    2020-01-01 open Assets:Bank:HSBC HKD
    2020-01-01 open Liabilities:CreditCard:SPDB CNY
    2020-01-01 open Assets:EWallet:WeChatPay CNY
    2020-01-01 open Expenses:Food:Dining
    2020-01-01 open Expenses:Shopping:Digital
    2020-01-01 open Expenses:Shopping:Clothing
    2020-01-01 open Expenses:Transit:Taxi
    2020-01-01 open Income:Rewards
    2026-09-01 price CNY 1.18 HKD

    2026-09-01 * "淘宝" "iwatch 表带"
      Expenses:Shopping:Digital                          50.00 CNY
      Assets:Bank:BOC                                   -50.00 CNY

    2026-09-02 * "淘宝" "T恤"
      Expenses:Shopping:Clothing                         60.00 CNY
      Assets:Bank:BOC                                   -60.00 CNY

    2026-10-08 * "宝贝母婴店" "奶瓶"
      Expenses:Shopping:Digital                           9.90 CNY
      Assets:Bank:BOC                                    -9.90 CNY

    2026-10-13 * "金牌烧鹅示例店" "午饭"
      order: "4200000001202610130000000011"
      Expenses:Food:Dining                                4.00 CNY
      Assets:Bank:BOC                                    -4.00 CNY

    """
    private func ledger() -> (Ledger, Derived) {
        let L = loadLedger(root: "main.bean") { _ in self.ledgerText }
        return (L, Derived(L, today: "2026-10-15"))
    }

    func testDraftFromForeignCard() {
        let (L, D) = ledger()
        let plan = scanPlan(sample("wechat-detail-fx-1"), L, D, cards: ["2468": "Assets:Bank:HSBC"], defaultFunding: nil, today: "2026-10-15")
        let d = try! XCTUnwrap(plan.draft)
        XCTAssertEqual(d.funding, "Assets:Bank:HSBC")
        XCTAssertTrue(d.byRate); XCTAssertEqual(d.rate, "1.17972")
        let t = draftText(d, L, D)
        XCTAssertTrue(t.contains("90.23 CNY @ 1.17972 HKD") && t.contains("-106.45 HKD") && t.contains("order: \"4500000001202609300000000044\""), t)
        XCTAssertFalse(plan.checks.contains(.funding))
    }

    func testDraftCardByLastDigits() {
        let (L, D) = ledger()
        let plan = scanPlan(sample("wechat-detail-en-2"), L, D, defaultFunding: nil, today: "2026-10-15")
        XCTAssertEqual(plan.draft?.funding, "Assets:Bank:BOC")
        XCTAssertFalse(plan.checks.contains(.funding))
        XCTAssertNil(plan.duplicate)
        // the same payment, recorded already (same order number)
        XCTAssertEqual(scanPlan(sample("wechat-detail-en-1"), L, D, defaultFunding: nil).duplicate?.payee, "金牌烧鹅示例店")
    }

    func testDraftPlatformAndDiscount() {
        let (L, D) = ledger()
        var plan = scanPlan(sample("alipay-taobao-zh-1"), L, D, defaultFunding: nil, today: "2026-10-15")
        XCTAssertEqual(plan.draft?.payee, "淘宝")
        // "iwatch" was bought here before as Digital, not the last 淘宝 purchase's Clothing
        XCTAssertEqual(plan.draft?.account, "Expenses:Shopping:Digital")
        XCTAssertTrue(plan.checks.contains(.category))

        // a discount on a foreign card is only noted
        plan = scanPlan(sample("alipay-visa-discount-zh-1"), L, D, cards: ["2468": "Assets:Bank:HSBC"], defaultFunding: nil)
        XCTAssertEqual(plan.draft?.amount, "194.14")
        XCTAssertTrue(plan.draft?.narration.contains("立减 0.86") ?? false)
        XCTAssertTrue(plan.checks.contains(.charged))
    }

    func testRefundFindsItsPurchase() {
        let (L, D) = ledger()
        let plan = scanPlan(sample("alipay-refund-zh-1"), L, D, defaultFunding: nil, today: "2026-10-15")
        XCTAssertEqual(plan.refundOf.first?.payee, "宝贝母婴店")
        let d = try! XCTUnwrap(plan.draft)
        XCTAssertEqual(d.kind, .refund)
        XCTAssertEqual(d.date, "2026-10-10")
        XCTAssertEqual(d.funding, "Assets:Bank:BOC")
        XCTAssertNotNil(d.refundOf)
    }

    func testProblems() {
        let (L, D) = ledger()
        XCTAssertNotNil(scanPlan(sample("wechat-pay-notices-en-1"), L, D, defaultFunding: nil).problem)
        let plan = scanPlan(sample("wechat-success-zh-1"), L, D, defaultFunding: "Assets:EWallet:WeChatPay", today: "2026-10-15")
        XCTAssertEqual(plan.draft?.date, "2026-10-15")
        XCTAssertEqual(plan.draft?.funding, "Assets:EWallet:WeChatPay")
        XCTAssertTrue(plan.checks.contains(.date) && plan.checks.contains(.funding))
    }
}
