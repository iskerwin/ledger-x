import Foundation

// 截图记账: the text read off a payment screenshot (ocrText: rows, pieces on a row separated by a tab), read
// as a payment. WeChat (Chinese and English screens) and Alipay bill details, WeChat's 支付成功 page and its
// foreign-card details (local price + exchange rate). Then `scanPlan` turns it into a 记一笔 draft using the
// ledger: the paying account by the card's last four digits, the payee and category as recorded before.

public enum ScanSource: String, Codable { case wechat, alipay, unknown }
public enum ScanKind: Codable, Equatable { case payment, refund, transfer, several(Int) }

/// what a screenshot says about one payment
public struct ScanFields: Codable, Equatable {
    public var source = ScanSource.unknown
    public var kind = ScanKind.payment
    /// what was paid, in the bill's currency (always positive)
    public var amount: Double?
    public var currency = "CNY"
    /// a foreign card: what the card was charged, in its currency (HK$106.45)
    public var charged: Double?
    public var chargedCurrency: String?
    /// the receipt's rate: 1 `rateBase` = `rate` `rateQuote` ("1CNY=1.17972HKD")
    public var rate: String?
    public var rateBase: String?
    public var rateQuote: String?
    public var date: String?
    public var time: String?
    /// the name as shown at the top ("喜市多"); `payeeFull` the merchant's registered name
    public var payee: String?
    public var payeeFull: String?
    /// the name has stars in it ("宝贝**店")
    public var masked = false
    /// a platform the shop is on (淘宝 for an Alipay bill marked 淘)
    public var platform: String?
    public var note: String?
    /// the paying (or refunded-to) method as written, and its last four digits
    public var method: String?
    public var last4: String?
    public var orderNo: String?
    /// the app's own category ("餐饮美食")
    public var category: String?
    /// a discount taken off (碰一下立减 0.86) and the price before it
    public var discount: Double?
    public var listPrice: Double?
    public init() {}
}

private let amountRE = try! NSRegularExpression(pattern: #"^([-+－])?\s*(HK\$|US\$|\$|¥|￥|€|£)?\s*(\d[\d,]*\.\d{2})$"#)
private let dateRE = try! NSRegularExpression(pattern: #"(\d{4})\s*[-/年]\s*(\d{1,2})\s*[-/月]\s*(\d{1,2})\s*日?\s*(\d{1,2}:\d{2}(?::\d{2})?)?"#)
private let last4RE = try! NSRegularExpression(pattern: #"[（(]\s*(\d{4})\s*[）)]"#)
private let rateRE = try! NSRegularExpression(pattern: #"1\s*([A-Z]{3})\s*[=＝]\s*([\d.]+)\s*([A-Z]{3})"#)
private let longIdRE = try! NSRegularExpression(pattern: #"[A-Z0-9]{16,}"#)

private func groups(_ re: NSRegularExpression, _ s: String) -> [String?]? {
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
}

private func clean(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespaces)
    while let l = t.last, "＞>》〉".contains(l) { t.removeLast(); t = t.trimmingCharacters(in: .whitespaces) }
    return t
}

private func currencyOf(_ sym: String?) -> String {
    switch sym {
    case "HK$": return "HKD"
    case "US$", "$": return "USD"
    case "€": return "EUR"
    case "£": return "GBP"
    default: return "CNY"
    }
}

/// a row: its pieces (label first when there are two or more)
private struct Row { var cells: [String]; var text: String { cells.joined(separator: " ") } }

/// labels written on two lines on English screens ("Payment" / "Time")
private let labelTails: Set<String> = ["Time", "Method", "Status", "Order No.", "No."]

public func parseScan(_ text: String) -> ScanFields {
    var f = ScanFields()
    var rows = text.components(separatedBy: "\n").map { Row(cells: $0.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) }
        .filter { !$0.cells.isEmpty }
    // the status bar (clock, signal, battery) comes first
    if let first = rows.first, let c = first.text.first, c.isNumber, amountLine(first.text) == nil { rows.removeFirst() }
    let all = rows.map { $0.text }.joined(separator: "\n")

    // which app
    if all.contains("账单详情") && (all.contains("付款方式") || all.contains("退款方式") || all.contains("账单分类") || all.contains("对方账户")) {
        f.source = .alipay
    } else if all.contains("Transactions") || all.contains("Weixin Pay") || all.contains("当前状态") || all.contains("支付成功")
                || all.contains("Payment Method") || all.contains("Paid by") || all.contains("转账单号") || all.contains("财付通") {
        f.source = .wechat
    }

    // several payments on one screen (WeChat Pay notices)
    let paidBy = rows.filter { $0.text.hasPrefix("Paid by") || $0.text.hasPrefix("Transaction Details") }.count
    let notices = rows.filter { $0.text.hasPrefix("Paid by") }.count
    if notices >= 2 || (paidBy >= 4) { f.kind = .several(max(notices, paidBy / 2)); return f }

    // label → value, a label's second line joined on
    var fields: [(label: String, value: String, row: Int)] = []
    for (i, r) in rows.enumerated() where r.cells.count >= 2 {
        var label = r.cells[0]
        if i + 1 < rows.count, rows[i + 1].cells.count == 1, labelTails.contains(rows[i + 1].cells[0]), label.first?.isLetter == true, label.unicodeScalars.first!.isASCII {
            label += " " + rows[i + 1].cells[0]
        }
        fields.append((label, r.cells.dropFirst().joined(separator: " "), i))
    }
    func value(_ labels: [String]) -> (String, Int)? {
        for l in labels { if let x = fields.first(where: { $0.label == l }) { return (x.value, x.row) } }
        return nil
    }

    // the amount: the first line that is only an amount
    guard let ai = rows.firstIndex(where: { $0.cells.count == 1 && amountLine($0.text) != nil }), let a = amountLine(rows[ai].text) else { return f }
    f.amount = a.amount
    f.currency = a.currency

    let refund = all.contains("退款成功") || all.contains("退款方式") || rows.contains { $0.text == "退" }
    if refund { f.kind = .refund }
    else if all.contains("对方账户") || all.contains("转账备注") { f.kind = .transfer }

    // a foreign card: the bill's own price and the rate; the amount above is what the card was charged
    if let (lp, _) = value(["Local Price", "本地价格", "标价"]), let p = amountLine(lp) {
        f.charged = f.amount; f.chargedCurrency = f.currency
        f.amount = p.amount; f.currency = p.currency
    }
    if let (r, _) = value(["Exchange Rate", "汇率"]), let g = groups(rateRE, r.replacingOccurrences(of: " ", with: "")) {
        f.rateBase = g[1]; f.rate = g[2]; f.rateQuote = g[3]
    }
    // a discount taken off the order's price (碰一下立减 -0.86)
    if let (o, _) = value(["订单金额", "Order Amount"]), let p = amountLine(o) { f.listPrice = p.amount }
    if let d = fields.first(where: { ($0.label.contains("立减") || $0.label.contains("优惠") || $0.label.contains("红包抵扣") || $0.label.contains("Discount"))
        && amountLine($0.value) != nil }), let p = amountLine(d.value), p.amount > 0 {
        f.discount = p.amount
    }

    // when: the first full date (a labelled payment time comes first on every screen)
    for r in rows where !r.text.contains("至") {
        if let g = groups(dateRE, r.text), let y = g[1], let m = g[2], let d = g[3], let yi = Int(y), let mi = Int(m), let di = Int(d),
           (1...12).contains(mi), (1...31).contains(di) {
            f.date = String(format: "%04d-%02d-%02d", yi, mi, di)
            f.time = g[4]
            break
        }
    }

    // who: the nearest line above the amount that is a name (not a heading, not a one-letter mark)
    var j = ai - 1
    let headings: Set<String> = ["账单详情", "Transactions", "Transactions All transactions", "X", "支付成功", "• 支付成功", "Weixin Pay"]
    while j >= 0 {
        let t = rows[j].text
        let last = rows[j].cells.last ?? t
        if t.count <= 1 || last.count <= 1 { j -= 1; continue }
        if headings.contains(t) || headings.contains(last) || t.hasSuffix("Transactions All transactions") { break }
        var name = clean(last)
        if let r = name.range(of: "给", options: .backwards), name.hasPrefix("扫") || name.contains("付款-") { name = String(name[r.upperBound...]) }
        if let bar = name.firstIndex(where: { $0 == "｜" || $0 == "|" }) { name = String(name[..<bar]) }
        // a person: 好心人（**明） → the nickname
        if let p = name.firstIndex(where: { $0 == "（" || $0 == "(" }), name[p...].contains("*") { name = String(name[..<p]) }
        f.masked = name.contains("*")
        f.payee = name.trimmingCharacters(in: .whitespaces)
        break
    }
    if let (v, _) = value(["收款方全称", "Merchant", "商户全称"]) { f.payeeFull = clean(v) }
    // a shop on a platform: its mark above the (starred) shop name
    if rows[..<ai].contains(where: { $0.text == "淘" }) { f.platform = "淘宝" }
    else if rows[..<ai].contains(where: { $0.text == "猫" || $0.text == "天猫" }) { f.platform = "天猫" }

    // how it was paid
    if let (v, _) = value(["付款方式", "支付方式", "退款方式", "Payment Method"]) { f.method = clean(v) }
    else if let r = rows.first(where: { $0.text.hasPrefix("Paid by") }) { f.method = clean(String(r.text.dropFirst("Paid by".count))) }
    if let m = f.method, let g = groups(last4RE, m) { f.last4 = g[1] }

    // the order number: a long run of digits after its label, its end wrapped onto the next line
    for (i, r) in rows.enumerated() where ["交易单号", "转账单号", "Transaction No.", "Transaction"].contains(where: { r.text.hasPrefix($0) }) {
        guard let g = groups(longIdRE, r.text), var id = g[0] else { continue }
        if i + 1 < rows.count, rows[i + 1].cells.count == 1, rows[i + 1].text.range(of: #"^\d{1,6}$"#, options: .regularExpression) != nil {
            id += rows[i + 1].text
        }
        f.orderNo = id
        break
    }

    // what it was for
    // (WeChat's "Products" is the till's name, not what was bought)
    if let (v, _) = value(["商品说明", "Transaction Item"]) { f.note = clean(v) }
    if f.platform != nil, let i = rows.firstIndex(where: { $0.text == "交易详情" }), i + 1 < rows.count { f.note = rows[i + 1].text }
    if let from = rows.first(where: { $0.text.hasPrefix("出发：") }), let to = rows.first(where: { $0.text.contains("到达：") }) {
        func station(_ s: String, _ k: String) -> String {
            var x = s.components(separatedBy: k).last ?? s
            if x.hasPrefix("广东") { x.removeFirst(2) }
            return x.trimmingCharacters(in: .whitespaces)
        }
        f.note = station(from.text, "出发：") + " → " + station(to.text, "到达：")
    }
    if let (v, _) = value(["转账备注"]), !["Transfer", "转账"].contains(v) { f.note = v }
    if let n = f.note, n == f.payee || n == f.payeeFull { f.note = nil }
    if let (v, _) = value(["账单分类"]) { f.category = clean(v) }
    return f
}

/// "−HK$106.45", "¥4.00", "9.90" → the amount (positive) and its currency
private func amountLine(_ s: String) -> (amount: Double, currency: String)? {
    guard let g = groups(amountRE, s.trimmingCharacters(in: .whitespaces)), let n = g[3], let v = Double(n.replacingOccurrences(of: ",", with: "")) else { return nil }
    return (v, currencyOf(g[2]))
}
