import Foundation
#if canImport(Compression)
import Compression
#endif

// Importing bills exported by Alipay, WeChat Pay and banks (CSV or XLSX).

public enum ImportSource: String, Codable, CaseIterable {
    case alipay, wechat, bank
    public var name: String {
        switch self {
        case .alipay: return tr("支付宝", "Alipay")
        case .wechat: return tr("微信支付", "WeChat Pay")
        case .bank: return tr("银行 / 其他", "Bank / other")
        }
    }
}

public enum ImportDirection: String, Codable {
    case expense, income, neutral
}

public struct ImportRow: Identifiable, Equatable {
    public var id: Int
    public var date: String
    public var time = ""
    public var payee = ""
    public var narration = ""
    public var amount = 0.0          // always positive
    public var direction = ImportDirection.expense
    public var method = ""           // how it was paid ("招商银行信用卡(1234)", "余额", "零钱")
    public var status = ""
    public var orderID = ""
    public var category = ""         // the exporter's own category ("餐饮美食")
    public var note = ""
    public init(id: Int, date: String) { self.id = id; self.date = date }
}

/// column positions for a generic (bank) table; -1 = not present
public struct ImportColumns: Equatable, Codable {
    public var date = -1, amount = -1, debit = -1, credit = -1, payee = -1, narration = -1, method = -1
    public var status = -1, order = -1, category = -1, note = -1, direction = -1
    public init() {}
}

public struct ImportTable {
    public var source: ImportSource
    public var header: [String]
    public var body: [[String]]
    public var columns: ImportColumns
    public var rows: [ImportRow]
    /// rows left out (closed or failed payments, unparsable lines)
    public var skipped: Int
}

// MARK: - decoding

/// UTF-8 (with or without BOM), UTF-16, else GB18030 (what Alipay uses)
public func decodeBillText(_ d: Data) -> String {
    if d.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: d.dropFirst(3), encoding: .utf8) { return s }
    if d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF]), let s = String(data: d, encoding: .utf16) { return s }
    if let s = String(data: d, encoding: .utf8) { return s }
    let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    if let s = String(data: d, encoding: String.Encoding(rawValue: gb)) { return s }
    return String(decoding: d, as: UTF8.self)
}

/// RFC 4180 CSV (quotes, doubled quotes, newlines in quotes); also accepts tab-separated text
public func parseCSV(_ text: String) -> [[String]] {
    let firstLine = text.prefix(while: { $0 != "\n" })
    let sep: Character = firstLine.filter { $0 == "\t" }.count > firstLine.filter { $0 == "," }.count ? "\t" : ","
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    var it = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    if it.first == "\u{FEFF}" { it.removeFirst() }
    var i = 0
    while i < it.count {
        let c = it[i]
        if inQuotes {
            if c == "\"" {
                if i + 1 < it.count && it[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
            } else { field.append(c) }
        } else if c == "\"" && field.trimmingCharacters(in: .whitespaces).isEmpty {
            inQuotes = true
            field = ""
        } else if c == sep {
            row.append(field); field = ""
        } else if c == "\n" {
            row.append(field); field = ""
            rows.append(row); row = []
        } else {
            field.append(c)
        }
        i += 1
    }
    if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
    return rows.map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
}

// MARK: - XLSX (WeChat exports .xlsx)

/// read the first worksheet of an .xlsx file as rows of text
public func parseXLSX(_ data: Data) -> [[String]]? {
    guard let files = unzip(data) else { return nil }
    var shared: [String] = []
    if let ss = files["xl/sharedStrings.xml"] { shared = XLSXStrings.parse(ss) }
    let sheetName = files.keys.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }.sorted().first
    guard let name = sheetName, let sheet = files[name] else { return nil }
    return XLSXSheet.parse(sheet, shared: shared)
}

/// entries of a ZIP archive (stored or deflated)
public func unzip(_ data: Data) -> [String: Data]? {
    let b = [UInt8](data)
    func u16(_ o: Int) -> Int { o + 1 < b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
    func u32(_ o: Int) -> Int { o + 3 < b.count ? u16(o) | u16(o + 2) << 16 : 0 }
    // end of central directory
    guard b.count > 22 else { return nil }
    var eocd = -1
    var k = b.count - 22
    while k >= max(0, b.count - 65_557) {
        if u32(k) == 0x06054b50 { eocd = k; break }
        k -= 1
    }
    guard eocd >= 0 else { return nil }
    let count = u16(eocd + 10)
    var p = u32(eocd + 16)
    var out: [String: Data] = [:]
    for _ in 0..<count {
        guard u32(p) == 0x02014b50 else { return nil }
        let method = u16(p + 10)
        let csize = u32(p + 20), usize = u32(p + 24)
        let nlen = u16(p + 28), xlen = u16(p + 30), clen = u16(p + 32)
        let local = u32(p + 42)
        let name = String(decoding: b[(p + 46)..<min(b.count, p + 46 + nlen)], as: UTF8.self)
        p += 46 + nlen + xlen + clen
        guard u32(local) == 0x04034b50 else { continue }
        let start = local + 30 + u16(local + 26) + u16(local + 28)
        guard start + csize <= b.count else { continue }
        let comp = Data(b[start..<(start + csize)])
        if method == 0 { out[name] = comp }
        else if method == 8, let d = inflate(comp, size: usize) { out[name] = d }
    }
    return out
}

func inflate(_ d: Data, size: Int) -> Data? {
    #if canImport(Compression)
    let cap = max(size, 64)
    var dst = [UInt8](repeating: 0, count: cap)
    let n = d.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
        guard let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return compression_decode_buffer(&dst, cap, s, d.count, nil, COMPRESSION_ZLIB)
    }
    return n > 0 ? Data(dst[0..<n]) : nil
    #else
    return nil
    #endif
}

final class XLSXStrings: NSObject, XMLParserDelegate {
    var out: [String] = []
    var cur = ""
    var inT = false
    var inSI = false
    static func parse(_ d: Data) -> [String] {
        let me = XLSXStrings()
        let p = XMLParser(data: d)
        p.delegate = me
        p.parse()
        return me.out
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "si" { inSI = true; cur = "" }
        if name == "t" { inT = true }
        if name == "rPh" { inT = false }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if inSI && inT { cur += s } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inT = false }
        if name == "si" { out.append(cur); inSI = false }
    }
}

final class XLSXSheet: NSObject, XMLParserDelegate {
    var rows: [[String]] = []
    var row: [Int: String] = [:]
    var col = 0
    var type = ""
    var text = ""
    var inV = false
    var shared: [String] = []

    static func parse(_ d: Data, shared: [String]) -> [[String]] {
        let me = XLSXSheet()
        me.shared = shared
        let p = XMLParser(data: d)
        p.delegate = me
        p.parse()
        return me.rows
    }

    static func column(_ ref: String) -> Int {
        var n = 0
        for ch in ref.unicodeScalars {
            guard ch.value >= 65 && ch.value <= 90 else { break }
            n = n * 26 + Int(ch.value - 64)
        }
        return max(0, n - 1)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch name {
        case "row": row = [:]; col = 0
        case "c":
            if let r = a["r"] { col = XLSXSheet.column(r) }
            type = a["t"] ?? ""
            text = ""
        case "v", "t": inV = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if inV { text += s } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t": inV = false
        case "c":
            var v = text
            if type == "s", let i = Int(text), i < shared.count { v = shared[i] }
            row[col] = v
            col += 1
        case "row":
            let n = (row.keys.max() ?? -1) + 1
            rows.append((0..<n).map { (row[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) })
        default: break
        }
    }
}

// MARK: - reading a bill

private let colNames: [(WritableKeyPath<ImportColumns, Int>, [String])] = [
    (\.date, ["交易时间", "交易创建时间", "付款时间", "交易日期", "记账日期", "日期", "date", "transaction date", "posting date"]),
    (\.payee, ["交易对方", "对方户名", "对方名称", "对方账户名", "商户名称", "payee", "description", "merchant"]),
    (\.narration, ["商品说明", "商品名称", "商品", "交易摘要", "摘要", "用途", "附言", "memo", "narration"]),
    (\.direction, ["收/支", "收支", "收/支类型"]),
    (\.amount, ["金额", "金额(元)", "金额（元）", "交易金额", "amount"]),
    (\.debit, ["支出", "支出金额", "借方发生额", "借方金额", "debit", "withdrawal"]),
    (\.credit, ["收入", "收入金额", "存入金额", "贷方发生额", "贷方金额", "credit", "deposit"]),
    (\.method, ["收/付款方式", "支付方式", "付款方式"]),
    (\.status, ["交易状态", "当前状态", "状态"]),
    (\.order, ["交易订单号", "交易单号", "交易号", "流水号", "交易流水号"]),
    (\.category, ["交易分类", "交易类型", "类型"]),
    (\.note, ["备注"]),
]

/// find the header row and the columns we know
public func guessColumns(_ rows: [[String]]) -> (header: Int, columns: ImportColumns) {
    var best = (header: 0, columns: ImportColumns(), score: 0)
    for (i, r) in rows.prefix(40).enumerated() {
        var c = ImportColumns()
        var score = 0
        let cells = r.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        for (kp, names) in colNames {
            if let k = cells.firstIndex(where: { cell in names.contains(where: { cell == $0.lowercased() }) }) {
                c[keyPath: kp] = k
                score += 1
            }
        }
        if c.date >= 0 && (c.amount >= 0 || c.debit >= 0 || c.credit >= 0) && score > best.score { best = (i, c, score) }
    }
    return (best.header, best.columns)
}

func parseAmount(_ s: String) -> Double? {
    let t = s.replacingOccurrences(of: "¥", with: "").replacingOccurrences(of: "￥", with: "")
        .replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "")
        .replacingOccurrences(of: "元", with: "").replacingOccurrences(of: "CNY", with: "")
        .trimmingCharacters(in: .whitespaces)
    if t.isEmpty || t == "/" || t == "-" || t == "--" { return nil }
    return Double(t)
}

/// "2026-10-08 12:34:56", "2026/10/8 12:34", "20261008", an Excel serial number → ("2026-10-08", "12:34")
func parseDateTime(_ s: String) -> (String, String)? {
    let t = s.trimmingCharacters(in: .whitespaces)
    if let n = Double(t), n > 20000, n < 80000 {
        // Excel serial (days since 1899-12-30)
        let secs = (n - 25569) * 86400
        let d = Date(timeIntervalSince1970: secs)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        return (String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!), String(format: "%02d:%02d", c.hour!, c.minute!))
    }
    if t.count == 8, let _ = Int(t) {
        let a = Array(t)
        return ("\(String(a[0..<4]))-\(String(a[4..<6]))-\(String(a[6..<8]))", "")
    }
    let parts = t.split(whereSeparator: { $0 == " " || $0 == "T" })
    guard let d0 = parts.first else { return nil }
    let nums = d0.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." || $0 == "年" || $0 == "月" || $0 == "日" }).compactMap { Int($0) }
    guard nums.count == 3, nums[0] > 1900 else { return nil }
    let time = parts.count > 1 ? String(parts[1].prefix(5)) : ""
    return (String(format: "%04d-%02d-%02d", nums[0], nums[1], nums[2]), time)
}

/// read a bill exported from Alipay, WeChat Pay or a bank
public func readBill(_ data: Data, fileName: String = "", columns: ImportColumns? = nil) -> ImportTable? {
    var rows: [[String]]
    var raw = ""
    if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
        guard let r = parseXLSX(data) else { return nil }
        rows = r
        raw = r.prefix(20).map { $0.joined(separator: ",") }.joined(separator: "\n")
    } else {
        raw = decodeBillText(data)
        rows = parseCSV(raw)
    }
    rows = rows.filter { !$0.allSatisfy { $0.isEmpty } }
    guard !rows.isEmpty else { return nil }
    let head = raw.prefix(3000)
    let source: ImportSource = head.contains("支付宝") || fileName.contains("alipay") ? .alipay
        : head.contains("微信支付") || fileName.contains("微信") || fileName.lowercased().contains("wechat") ? .wechat : .bank
    let g = guessColumns(rows)
    let c = columns ?? g.columns
    let header = rows[g.header]
    let body = Array(rows[(g.header + 1)...])
    return ImportTable(source: source, header: header, body: body, columns: c, rows: [], skipped: 0).withRows()
}

extension ImportTable {
    /// (re)build the rows from the body with the current columns
    public func withRows() -> ImportTable {
        var t = self
        var out: [ImportRow] = []
        var skipped = 0
        func cell(_ r: [String], _ i: Int) -> String { i >= 0 && i < r.count ? r[i] : "" }
        for (i, r) in body.enumerated() {
            guard let dt = parseDateTime(cell(r, columns.date)) else { skipped += 1; continue }
            var row = ImportRow(id: i, date: dt.0)
            row.time = dt.1
            row.payee = cell(r, columns.payee).replacingOccurrences(of: "\"", with: "")
            row.narration = cell(r, columns.narration).replacingOccurrences(of: "\"", with: "")
            if row.narration == "/" { row.narration = "" }
            row.method = cell(r, columns.method)
            row.status = cell(r, columns.status)
            row.orderID = cell(r, columns.order).trimmingCharacters(in: CharacterSet(charactersIn: "\t "))
            row.category = cell(r, columns.category)
            row.note = cell(r, columns.note)
            if row.note == "/" { row.note = "" }
            let dir = cell(r, columns.direction)
            var amount: Double?
            if columns.amount >= 0, let a = parseAmount(cell(r, columns.amount)) {
                amount = a
            } else {
                let dr = parseAmount(cell(r, columns.debit)) ?? 0, cr = parseAmount(cell(r, columns.credit)) ?? 0
                if dr != 0 || cr != 0 { amount = cr - dr }
            }
            guard let a = amount, abs(a) > 0.0001 else { skipped += 1; continue }
            if dir.contains("支出") { row.direction = .expense }
            else if dir.contains("收入") { row.direction = .income }
            else if columns.direction >= 0 { row.direction = .neutral }
            else { row.direction = a < 0 ? .expense : .income }
            row.amount = abs(a)
            // payments that did not happen
            if ["关闭", "失败", "已撤销", "已取消"].contains(where: { row.status.contains($0) }) { skipped += 1; continue }
            out.append(row)
        }
        t.rows = out
        t.skipped = skipped
        return t
    }
}

// MARK: - matching to the ledger

private let BANKS: [(String, [String])] = [
    ("招商", ["CMB"]), ("工商", ["ICBC"]), ("建设", ["CCB"]), ("农业", ["ABC"]), ("中国银行", ["BOC"]), ("交通", ["BOCOM", "BCM", "COMM"]),
    ("广发", ["CGB", "GDB"]), ("浦发", ["SPDB"]), ("兴业", ["CIB"]), ("民生", ["CMBC"]), ("中信", ["CITIC"]), ("光大", ["CEB"]),
    ("平安", ["PAB", "PINGAN"]), ("邮储", ["PSBC"]), ("邮政", ["PSBC"]), ("华夏", ["HXB"]), ("北京银行", ["BOB"]), ("上海银行", ["BOS"]),
    ("宁波银行", ["NBCB"]), ("微众", ["WEBANK"]),
]

/// the ledger account a payment method most likely is ("招商银行信用卡(1234)" → Liabilities:CreditCard:CMB)
public func guessFunding(_ method: String, source: ImportSource, _ L: Ledger, _ D: Derived) -> String? {
    let open = D.openAccounts
    func find(_ test: (String) -> Bool) -> String? { open.filter(test).max { (D.acctUse[$0] ?? 0) < (D.acctUse[$1] ?? 0) } }
    let m = method
    if m.contains("花呗") { return find { $0.hasPrefix("Liabilities") && ($0.lowercased().contains("huabei") || $0.lowercased().contains("alipay")) } }
    if m.contains("白条") { return find { $0.hasPrefix("Liabilities") && $0.lowercased().contains("baitiao") } }
    if m.contains("余额宝") { return find { $0.hasPrefix("Assets") && $0.lowercased().contains("yuebao") } ?? find { $0.hasPrefix("Assets") && $0.lowercased().contains("alipay") } }
    for (zh, codes) in BANKS where m.contains(zh) {
        let credit = m.contains("信用")
        if let a = find({ a in
            let up = a.uppercased()
            return codes.contains(where: { up.contains(":" + $0) }) && (credit ? a.hasPrefix("Liabilities") : a.hasPrefix("Assets"))
        }) { return a }
    }
    if m.contains("零钱") || m.contains("余额") || m.isEmpty || m == "/" {
        switch source {
        case .alipay: return find { $0.hasPrefix("Assets") && $0.lowercased().contains("alipay") }
        case .wechat: return find { $0.hasPrefix("Assets") && $0.lowercased().contains("wechat") }
        case .bank: return nil
        }
    }
    return nil
}

private let CATEGORY_GROUPS: [(String, [String])] = [
    ("餐饮", ["Food"]), ("美食", ["Food"]), ("外卖", ["Food"]), ("交通", ["Transit", "Transport"]), ("出行", ["Transit", "Transport"]),
    ("购物", ["Shopping"]), ("日用", ["Shopping"]), ("服饰", ["Shopping"]), ("数码", ["Shopping"]), ("超市", ["Food", "Shopping"]),
    ("住房", ["Housing"]), ("物业", ["Housing"]), ("水电", ["Housing"]), ("充值缴费", ["Subscription", "Housing"]), ("通讯", ["Subscription"]),
    ("医疗", ["Healthcare", "Health"]), ("健康", ["Healthcare", "Health"]), ("酒店", ["Travel"]), ("旅行", ["Travel"]), ("机票", ["Travel"]),
    ("娱乐", ["Lifestyle", "Entertainment"]), ("运动", ["Lifestyle"]), ("教育", ["Education"]), ("公益", ["Charity"]), ("红包", ["Gifts"]),
    ("转账", []), ("还款", []),
]

/// the account the last transaction with this payee used, else one that fits the exporter's category
public func guessCategory(_ row: ImportRow, _ L: Ledger, _ D: Derived) -> String? {
    let root = row.direction == .income ? "Income:" : "Expenses:"
    if let p = D.payee(row.payee), let a = p.last.postings.first(where: { $0.account.hasPrefix(root) })?.account { return a }
    // a payee recorded under a slightly different name ("瑞幸咖啡" vs "瑞幸")
    let name = row.payee
    if name.count >= 2 {
        let hit = D.payees.filter { $0.name.count >= 2 && (name.contains($0.name) || $0.name.contains(name)) }.max { $0.n < $1.n }
        if let a = hit?.last.postings.first(where: { $0.account.hasPrefix(root) })?.account { return a }
    }
    let text = row.category + " " + row.narration + " " + row.payee
    for (zh, groups) in CATEGORY_GROUPS where text.contains(zh) {
        for g in groups {
            if let a = D.rankAccounts([root + g]).first(where: { $0.hasPrefix(root + g) }) { return a }
        }
    }
    return nil
}

/// an existing transaction that looks like this row (same order id, or same day ±1 and amount on the account)
public func findDuplicate(_ row: ImportRow, funding: String?, _ L: Ledger) -> Entry? {
    guard let d0 = Day.date(row.date) else { return nil }
    let lo = Day.string(d0.addingTimeInterval(-86400 * 1.5)), hi = Day.string(d0.addingTimeInterval(86400 * 1.5))
    for t in L.txns where t.date >= lo && t.date <= hi && !t.synthetic {
        if !row.orderID.isEmpty, case .string(let o)? = t.meta["order"], o == row.orderID { return t }
        for p in t.postings where abs(abs(p.units ?? 0) - row.amount) < 0.005 {
            if let f = funding, p.account == f { return t }
            if funding == nil && !row.payee.isEmpty && t.payee == row.payee { return t }
        }
    }
    return nil
}

/// the Beancount text for one imported row
public func importText(_ row: ImportRow, account: String, funding: String, currency: String = "CNY", flag: String = "*", keepOrder: Bool = true) -> String {
    var tx = TxDraft(date: row.date)
    tx.flag = flag
    tx.payee = row.payee
    tx.narration = row.narration.isEmpty ? row.note : row.narration
    if keepOrder && !row.orderID.isEmpty { tx.meta = [("order", row.orderID)] }
    let n = row.amount
    if row.direction == .income {
        tx.postings = [TxPosting(account: funding, amount: n, currency: currency), TxPosting(account: account, amount: -n, currency: currency)]
    } else {
        tx.postings = [TxPosting(account: account, amount: n, currency: currency), TxPosting(account: funding, amount: -n, currency: currency)]
    }
    return formatTxn(tx)
}
