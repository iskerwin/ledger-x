import Foundation

// MARK: - 明细搜索: the words of the search box, every one must match (like Fava's filter)

/// A parsed search box. Every condition must hold.
///
/// - words: payee, note, account (or its Chinese group name), person (`person:` on a personal receivable)
/// - `"两个 词"`: a phrase with a space in it
/// - `-word`: must not match
/// - `#tag`, `^link`, `!` (flagged)
/// - field: `account:` / `科目:` / `账户:`, `payee:` / `收付款方:`, `note:` / `备注:`, `person:` / `对方:`
/// - amounts: `35`, `>100`, `<50`, `100~200`
/// - dates: `2026`, `2026-07`, `2026-07-15`, `2026-Q3`; ranges `2026-07~2026-08`, `2026-07..2026-08`,
///   `2026-07 - 2026-08` (Fava's way) or two dates side by side `2026-07 2026-08`; relative: 今天 昨天 本周 上周
///   本月 上月 今年 去年 近30天 近3月 (so a saved search keeps meaning the current month)
/// - either of: `#出差|#旅行`, `#出差|旅行`, `科目:餐饮|交通` (the first word's field or # carries over)
public struct TxQuery {
    public enum Field: Equatable { case any, account, payee, note, person }
    public enum Cond: Equatable {
        case flag
        case tag(String)
        case link(String)
        case gt(Double)
        case lt(Double)
        case amount(Double, String)
        case amountRange(Double, Double)
        /// first and last day, inclusive
        case dates(String, String)
        case text(String, Field)
        indirect case not(Cond)
        /// any one of them (`a|b`)
        indirect case any([Cond])
    }

    /// today, for 本月 / 上月 …; tests set it
    public static var today: () -> String = { Day.today() }
    public let conds: [Cond]

    public init(_ q: String) {
        conds = TxQuery.parse(TxQuery.tokens(q))
    }

    public var isEmpty: Bool { conds.isEmpty }

    /// the date span the query keeps to, if any (the first and last day)
    public var dateSpan: (String, String)? {
        for c in conds {
            if case .dates(let a, let b) = c { return (a, b) }
            // either of several dates: from the first to the last
            if case .any(let xs) = c {
                let ds = xs.compactMap { x -> (String, String)? in if case .dates(let a, let b) = x { return (a, b) }; return nil }
                if ds.count == xs.count, let a = ds.map({ $0.0 }).min(), let b = ds.map({ $0.1 }).max() { return (a, b) }
            }
        }
        return nil
    }

    /// `L` lets an account be found by its `name:` too (招商银行 for Liabilities:CreditCard:CMB)
    public func matches(_ t: Entry, _ L: Ledger? = nil) -> Bool { conds.allSatisfy { TxQuery.test($0, t, L) } }

    // MARK: parsing

    /// words split on spaces, with "quoted phrases" (also “…” and 「…」) kept whole
    static func tokens(_ q: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        let close: [Character: Character] = ["\"": "\"", "“": "”", "「": "」"]
        for ch in q {
            if let qc = quote {
                if ch == qc { quote = nil } else { cur.append(ch) }
            } else if let c = close[ch], cur.isEmpty || cur.hasSuffix(":") || cur == "-" {
                quote = c
            } else if ch == " " || ch == "\u{3000}" {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// `2026`, `2026-07`, `2026-07-15`, `2026-Q3` as first and last day
    static func dateSpan(_ w: String) -> (String, String)? {
        if let r = relativeSpan(w) { return r }
        let s = w.uppercased()
        if s.range(of: #"^\d{4}$"#, options: .regularExpression) != nil, let y = Int(s), (1900...2100).contains(y) {
            return (s + "-01-01", s + "-12-31")
        }
        if s.range(of: #"^\d{4}-Q[1-4]$"#, options: .regularExpression) != nil {
            let y = String(s.prefix(4)), q = Int(String(s.last!))!
            let m1 = String(format: "%@-%02d", y, q * 3 - 2), m3 = String(format: "%@-%02d", y, q * 3)
            return (m1 + "-01", Day.monthEnd(m3))
        }
        if s.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil { return (s + "-01", Day.monthEnd(s)) }
        if s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return (s, s) }
        return nil
    }

    /// 今天 昨天 本周 上周 本月 上月 今年 去年 近N天 近N月 (近N月 counts this month), from `today`
    static func relativeSpan(_ w: String) -> (String, String)? {
        let t = today(), ym = Day.ym(t), y = Int(t.prefix(4)) ?? 2000
        switch w {
        case "今天", "today": return (t, t)
        case "昨天", "yesterday": let d = Day.shift(t, -1); return (d, d)
        case "本周", "this-week", "上周", "last-week":
            // the same week start as the month grid: the phone's calendar, not a fixed Monday
            return Day.weekSpan(containing: t, lastWeek: w == "上周" || w == "last-week")
        case "本月", "this-month": return (ym + "-01", Day.monthEnd(ym))
        case "上月", "last-month": let p = Day.addMonth(ym, -1); return (p + "-01", Day.monthEnd(p))
        case "今年", "this-year": return ("\(y)-01-01", "\(y)-12-31")
        case "去年", "last-year": return ("\(y - 1)-01-01", "\(y - 1)-12-31")
        default: break
        }
        if let m = w.range(of: #"^近(\d{1,4})(天|日|月|个月)$"#, options: .regularExpression), m.lowerBound == w.startIndex {
            let n = Int(w.filter { $0.isNumber }) ?? 0
            guard n > 0 else { return nil }
            if w.hasSuffix("天") || w.hasSuffix("日") { return (Day.shift(t, -(n - 1)), t) }
            return (Day.addMonth(ym, -(n - 1)) + "-01", t)
        }
        return nil
    }

    /// a year is also a number: only a word with a dash, a quarter, a relative word or a year in a range is
    /// taken as a date alone
    static func isDateWord(_ w: String) -> Bool { (w.contains("-") || relativeSpan(w) != nil) && dateSpan(w) != nil }

    static func parse(_ ws: [String]) -> [Cond] {
        var out: [Cond] = []
        var i = 0
        while i < ws.count {
            let w = ws[i]
            // Fava's "2026-07 - 2026-08", or two dates side by side
            if let a = dateSpan(w), isDateWord(w) || (i + 1 < ws.count && (ws[i + 1] == "-" || ws[i + 1] == "~")) {
                if i + 2 < ws.count, ws[i + 1] == "-" || ws[i + 1] == "~" || ws[i + 1] == "..", let b = dateSpan(ws[i + 2]) {
                    out.append(.dates(min(a.0, b.0), max(a.1, b.1))); i += 3; continue
                }
                if i + 1 < ws.count, isDateWord(ws[i + 1]), let b = dateSpan(ws[i + 1]) {
                    out.append(.dates(min(a.0, b.0), max(a.1, b.1))); i += 2; continue
                }
                if isDateWord(w) { out.append(.dates(a.0, a.1)); i += 1; continue }
            }
            if w.count > 1, w.hasPrefix("-"), !(w.dropFirst().first?.isNumber ?? false) {
                if let c = word(String(w.dropFirst())) { out.append(.not(c)) }
            } else if let c = word(w) {
                out.append(c)
            }
            i += 1
        }
        return out
    }

    static let fields: [(String, Field)] = [
        ("account:", .account), ("科目:", .account), ("账户:", .account), ("acct:", .account),
        ("payee:", .payee), ("收付款方:", .payee), ("商户:", .payee),
        ("note:", .note), ("narration:", .note), ("备注:", .note), ("摘要:", .note),
        ("person:", .person), ("对方:", .person),
    ]

    static func word(_ w0: String) -> Cond? {
        // a full-width colon reads the same
        let w = w0.replacingOccurrences(of: "：", with: ":").replacingOccurrences(of: "｜", with: "|")
        // either of: the first word's field or # carries over to the rest ("#出差|旅行", "科目:餐饮|交通")
        if w.contains("|") {
            let parts = w.components(separatedBy: "|").filter { !$0.isEmpty }
            guard let first = parts.first else { return nil }
            var lead = ""
            if first.hasPrefix("#") || first.hasPrefix("^") { lead = String(first.prefix(1)) }
            else if let f = fields.first(where: { first.lowercased().hasPrefix($0.0) }) { lead = String(first.prefix(f.0.count)) }
            else if first.lowercased().hasPrefix("tag:") { lead = "tag:" }
            let cs = parts.enumerated().compactMap { i, p -> Cond? in
                // a later word with its own # or field keeps it
                let own = p.hasPrefix("#") || p.hasPrefix("^") || p.contains(":")
                return word(i == 0 || own || lead.isEmpty ? p : lead + p)
            }
            return cs.isEmpty ? nil : cs.count == 1 ? cs[0] : .any(cs)
        }
        if isDateWord(w), let d = dateSpan(w) { return .dates(d.0, d.1) }
        if w == "!" { return .flag }
        // a range dash left on its own
        if w == "-" || w == "~" || w == ".." { return nil }
        if w.hasPrefix("#") { return w.count > 1 ? .tag(String(w.dropFirst())) : nil }
        if w.hasPrefix("tag:") { return .tag(String(w.dropFirst(4))) }
        if w.hasPrefix("^") { return w.count > 1 ? .link(String(w.dropFirst())) : nil }
        for (p, f) in fields where w.lowercased().hasPrefix(p) {
            let v = String(w.dropFirst(p.count))
            return v.isEmpty ? nil : .text(v, f)
        }
        // a range: dates (2026-07~2026-08, 2025~2026) or amounts (100~200)
        for sep in ["~", ".."] where w.contains(sep) {
            let parts = w.components(separatedBy: sep)
            if parts.count == 2 {
                if let a = dateSpan(parts[0]), let b = dateSpan(parts[1]) { return .dates(min(a.0, b.0), max(a.1, b.1)) }
                if let a = Double(parts[0]), let b = Double(parts[1]) { return .amountRange(min(a, b), max(a, b)) }
            }
        }
        if w.range(of: #"^[<>]?\d+(\.\d+)?$"#, options: .regularExpression) != nil {
            let n = Double(w.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))) ?? 0
            if w.hasPrefix(">") { return .gt(n) }
            if w.hasPrefix("<") { return .lt(n) }
            return .amount(n, w)
        }
        if let d = dateSpan(w), w.uppercased().contains("Q") { return .dates(d.0, d.1) }
        return .text(w, .any)
    }

    // MARK: matching

    static func test(_ c: Cond, _ t: Entry, _ L: Ledger?) -> Bool {
        switch c {
        case .flag: return t.flag == "!"
        case .tag(let x): return t.tags.contains { $0.contains(x) }
        case .link(let x): return t.links.contains { $0.contains(x) }
        case .gt(let n): return t.postings.contains { abs($0.units ?? 0) > n }
        case .lt(let n): return t.postings.allSatisfy { abs($0.units ?? 0) < n }
        case .amount(let n, let raw):
            // a bare number may also be part of a date (15 → the 15th, 2026 → that year)
            return t.postings.contains { abs(abs($0.units ?? 0) - n) < 0.005 } || t.date.contains(raw)
        case .amountRange(let a, let b): return t.postings.contains { let v = abs($0.units ?? 0); return v >= a - 0.005 && v <= b + 0.005 }
        case .dates(let a, let b): return t.date >= a && t.date <= b
        case .not(let x): return !test(x, t, L)
        case .any(let xs): return xs.contains { test($0, t, L) }
        case .text(let x, let f):
            let lw = x.lowercased()
            let acct = { t.postings.contains { p in
                p.account.lowercased().contains(lw) || acctDisplay(p.account).contains(x)
                    || (L.map { accountTitle($0, p.account).lowercased().contains(lw) } ?? false) } }
            let person = { t.postings.contains { postingPerson($0)?.lowercased().contains(lw) ?? false } }
            switch f {
            case .payee: return t.payee.lowercased().contains(lw)
            case .note: return t.narration.lowercased().contains(lw)
            case .account: return acct()
            case .person: return person()
            case .any: return (t.payee + " " + t.narration).lowercased().contains(lw) || acct() || person()
            }
        }
    }
}
