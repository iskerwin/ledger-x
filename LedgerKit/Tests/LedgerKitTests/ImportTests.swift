import XCTest
@testable import LedgerKit

func loadSetText(_ set: String, _ path: String) throws -> String {
    try String(contentsOf: fixtureURL(set).appendingPathComponent(path), encoding: .utf8)
}

final class ImportTests: XCTestCase {
    lazy var L = loadSet("realistic")
    lazy var D = Derived(L, today: TODAY)

    let alipay = """
    ------------------------------------------------------------------------------------
    导出信息：
    姓名：某某
    支付宝账户：xxx@example.com
    ----------------------支付宝（中国）网络技术有限公司  电子客户回单----------------------
    交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注,
    2026-10-08 08:12:33,餐饮美食,瑞幸,/,拿铁,支出,9.90,招商银行信用卡(1234),交易成功,2026100822001\t,T123\t,,
    2026-10-07 19:01:02,日用百货,"京东商城, 自营",jd@x,纸巾,支出,12.80,余额,交易成功,2026100722002\t,,,
    2026-10-06 10:00:00,转账红包,张三,/,收款,收入,200.00,余额,交易成功,2026100622003\t,,,
    2026-10-05 10:00:00,日用百货,淘宝,/,退货,支出,15.00,余额,交易关闭,2026100522004\t,,,
    2026-10-04 10:00:00,投资理财,余额宝,/,转入,不计收支,500.00,余额,交易成功,2026100422005\t,,,
    """

    let wechat = """
    微信支付账单明细,,,,,,,,,,
    微信昵称：[某某],,,,,,,,,,
    ----------------------微信支付账单明细列表--------------------,,,,,,,,,,
    交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注
    2026-10-08 12:00:00,商户消费,美团,"午餐",支出,¥25.50,零钱,支付成功,4200001\t,10001\t,/
    2026-10-07 12:00:00,微信红包,李四,"/",收入,"¥66.00",/,已存入零钱,1000002\t,/,/
    """

    func testAlipay() throws {
        let t = try XCTUnwrap(readBill(Data(alipay.utf8)))
        XCTAssertEqual(t.source, .alipay)
        XCTAssertEqual(t.rows.count, 4)
        XCTAssertEqual(t.skipped, 1)   // the closed one
        let r = t.rows[0]
        XCTAssertEqual(r.date, "2026-10-08")
        XCTAssertEqual(r.payee, "瑞幸")
        XCTAssertEqual(r.narration, "拿铁")
        XCTAssertEqual(r.amount, 9.9, accuracy: 1e-9)
        XCTAssertEqual(r.direction, .expense)
        XCTAssertEqual(r.orderID, "2026100822001")
        XCTAssertEqual(t.rows[1].payee, "京东商城, 自营")
        XCTAssertEqual(t.rows[2].direction, .income)
        XCTAssertEqual(t.rows[3].direction, .neutral)
        XCTAssertEqual(guessFunding(r.method, source: .alipay, L, D), "Liabilities:CreditCard:CMB")
        XCTAssertEqual(guessFunding("余额", source: .alipay, L, D), "Assets:EWallet:Alipay")
        XCTAssertEqual(guessCategory(r, L, D), "Expenses:Food:Drinks")
        let text = importText(r, account: "Expenses:Food:Drinks", funding: "Liabilities:CreditCard:CMB")
        XCTAssertTrue(text.hasPrefix("2026-10-08 * \"瑞幸\" \"拿铁\"\n  order: \"2026100822001\"\n"))
        XCTAssertTrue(validateText(text, L).ok, validateText(text, L).msg ?? "")
    }

    func testGBKAndWeChat() throws {
        let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = try XCTUnwrap(alipay.data(using: String.Encoding(rawValue: gbk)))
        XCTAssertEqual(readBill(data)?.rows.count, 4)
        let w = try XCTUnwrap(readBill(Data(wechat.utf8)))
        XCTAssertEqual(w.source, .wechat)
        XCTAssertEqual(w.rows.count, 2)
        XCTAssertEqual(w.rows[0].amount, 25.5, accuracy: 1e-9)
        XCTAssertEqual(w.rows[0].orderID, "4200001")
        XCTAssertEqual(w.rows[1].direction, .income)
        XCTAssertEqual(w.rows[1].narration, "")
    }

    func testBankCSVAndDuplicates() throws {
        let bank = "记账日期,交易摘要,对方户名,支出,收入,余额\n20260925,工资,示例公司,,26800.00,100\n2026/10/02,消费,地铁,6.00,,94\n"
        let t = try XCTUnwrap(readBill(Data(bank.utf8)))
        XCTAssertEqual(t.source, .bank)
        XCTAssertEqual(t.rows.map { $0.direction }, [.income, .expense])
        XCTAssertEqual(t.rows[0].date, "2026-09-25")
        // something already in the ledger is found again
        let tx = try XCTUnwrap(L.txns.last { classify($0, L).kind == .expense && !$0.payee.isEmpty })
        let p = try XCTUnwrap(tx.postings.first { ($0.units ?? 0) < 0 })
        var row = ImportRow(id: 0, date: tx.date)
        row.payee = tx.payee
        row.amount = -(p.units ?? 0)
        XCTAssertNotNil(findDuplicate(row, funding: p.account, L))
        row.amount += 0.37
        XCTAssertNil(findDuplicate(row, funding: p.account, L))
    }

    /// a stored (uncompressed) zip with a tiny worksheet
    func testXLSX() throws {
        let shared = #"<sst><si><t>交易时间</t></si><si><t>交易对方</t></si><si><t>收/支</t></si><si><t>金额(元)</t></si><si><t>美团</t></si><si><t>支出</t></si></sst>"#
        let sheet = #"<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c></row><row r="2"><c r="A2"><v>46303.5</v></c><c r="B2" t="s"><v>4</v></c><c r="C2" t="s"><v>5</v></c><c r="D2" t="inlineStr"><is><t>¥18.00</t></is></c></row></sheetData></worksheet>"#
        let zip = storedZip(["xl/sharedStrings.xml": Data(shared.utf8), "xl/worksheets/sheet1.xml": Data(sheet.utf8)])
        let t = try XCTUnwrap(readBill(zip, fileName: "微信支付账单.xlsx"))
        XCTAssertEqual(t.rows.count, 1)
        XCTAssertEqual(t.rows[0].date, "2026-10-08")
        XCTAssertEqual(t.rows[0].payee, "美团")
        XCTAssertEqual(t.rows[0].amount, 18, accuracy: 1e-9)
    }

    func storedZip(_ files: [String: Data]) -> Data {
        var out = Data(), central = Data()
        func le16(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
        func le32(_ v: Int) -> Data { le16(v & 0xffff) + le16(v >> 16 & 0xffff) }
        for (name, d) in files.sorted(by: { $0.key < $1.key }) {
            let n = Data(name.utf8)
            let off = out.count
            out += le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(d.count) + le32(d.count) + le16(n.count) + le16(0) + n + d
            central += le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(d.count) + le32(d.count)
                + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(off) + n
        }
        let cdOff = out.count
        out += central
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(central.count) + le32(cdOff) + le16(0)
        return out
    }

    func testBudgets() throws {
        let text = """
        2026-01-01 custom "budget" Expenses:Food "monthly" 1000.00 CNY
        2026-01-01 custom "budget" Expenses:Transit "weekly" 70.00 CNY
        2026-06-01 custom "budget" Expenses:Food "monthly" 1500.00 CNY
        """
        let L2 = loadLedger(root: "main.bean") { p in
            if p == "main.bean" { return (try loadSetText("realistic", "main.bean")) + "\ninclude \"budget.bean\"\n" }
            if p == "budget.bean" { return text }
            return try loadSetText("realistic", p)
        }
        XCTAssertEqual(budgets(L2).count, 3)
        let act = activeBudgets(L2, at: "2026-10-01")
        XCTAssertEqual(act.first { $0.account == "Expenses:Food" }?.amount, 1500)
        let p = budgetProgress(L2, key: "2026-09", today: TODAY)
        let food = try XCTUnwrap(p.first { $0.budget.account == "Expenses:Food" })
        XCTAssertEqual(food.limit, 1500)
        var spent = 0.0
        for t in L2.txns where t.date.hasPrefix("2026-09") {
            for p in t.postings where p.account.hasPrefix("Expenses:Food") { spent += toCNY(L2, p.units ?? 0, p.currency ?? "CNY", t.date) ?? 0 }
        }
        XCTAssertGreaterThan(spent, 0)
        XCTAssertEqual(food.spent, spent, accuracy: 0.01)
        XCTAssertEqual(food.elapsed, 1)
        let transit = try XCTUnwrap(p.first { $0.budget.account == "Expenses:Transit" })
        XCTAssertEqual(transit.limit, 300, accuracy: 0.01)
        XCTAssertEqual(budgetProgress(L2, key: "2026", today: TODAY).first { $0.budget.account == "Expenses:Food" }?.limit, 18000)
        let line = budgetLine("2026-10-01", "Expenses:Food", .monthly, 2000, "CNY")
        XCTAssertTrue(line.hasPrefix("2026-10-01 custom \"budget\" Expenses:Food \"monthly\" "))
        XCTAssertTrue(line.hasSuffix(" 2000.00 CNY"))
    }
}
