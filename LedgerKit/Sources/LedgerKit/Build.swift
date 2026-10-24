import Foundation

// MARK: - weights, interpolation, booking

public struct Weight { public let n: Double; public let c: String }

public func weight(_ p: Posting) -> Weight? {
    guard let units = p.units, let currency = p.currency else { return nil }
    if let cost = p.cost, let num = cost.number, let cc = cost.currency { return Weight(n: units * num, c: cc) }
    if let pr = p.price, let pc = pr.currency, pr.number != nil || (pr.total && pr.raw != nil) {
        if pr.total { return Weight(n: sign(units) * abs(pr.raw!), c: pc) }
        return Weight(n: units * pr.number!, c: pc)
    }
    return Weight(n: units, c: currency)
}

/// the same weight on the decimal numbers as written (for amounts that are filled in and shown)
func decimalWeight(_ p: Posting) -> (n: Decimal, c: String)? {
    guard let units = p.units, let currency = p.currency else { return nil }
    if let cost = p.cost, let num = cost.number, let cc = cost.currency { return (decimalOf(units) * decimalOf(num), cc) }
    if let pr = p.price, let pc = pr.currency, pr.number != nil || (pr.total && pr.raw != nil) {
        if pr.total { return ((units < 0 ? -1 : 1) * decimalOf(abs(pr.raw!)), pc) }
        return (decimalOf(units) * decimalOf(pr.number!), pc)
    }
    return (decimalOf(units), currency)
}

/// What a posting breaks of its account's open line: used before the account opened, after it closed, or in a
/// currency the open line leaves out. The same check for the whole ledger and for a form before it is saved.
func accountUseErrors(_ t: Entry, _ p: Posting, _ acc: Account) -> [LedgerError] {
    var out: [LedgerError] = []
    func add(_ msg: String) { var e = LedgerError(entry: t, msg: msg); e.accountMisuse = true; out.append(e) }
    if let o = acc.open, t.date < o { add(tr("\(p.account) 在 \(o) 才开立", "\(p.account) is not open until \(o)")) }
    else if let c = acc.close, t.date > c { add(tr("\(p.account) 已于 \(c) 关闭", "\(p.account) was closed on \(c)")) }
    if !acc.currencies.isEmpty, let c = p.currency, !acc.currencies.contains(c) { add(tr("\(p.account) 不允许 \(c)", "\(p.account) does not allow \(c)")) }
    return out
}

/// How far a transaction may be off balance in each currency, as Beancount works it out: only numbers written
/// with decimals count (half the last digit, `inferred_tolerance_multiplier`); whole numbers set nothing. A
/// currency's own `inferred_tolerance_default` ("CNY:0.01") counts as well when the transaction uses it, the larger
/// one wins; a currency with nothing to go by uses "*:0.005" if set, else it must balance exactly.
struct BalanceTolerance {
    var multiplier: Decimal = 0.5
    var defaults: [String: Decimal] = [:]

    init(options: [String: [String?]]) {
        let posix = Locale(identifier: "en_US_POSIX")
        if let m = (options["inferred_tolerance_multiplier"]?.first ?? nil).flatMap({ Decimal(string: $0, locale: posix) }) { multiplier = m }
        for raw in options["inferred_tolerance_default"] ?? [] {
            let parts = (raw ?? "").split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let v = Decimal(string: parts[1], locale: posix) { defaults[parts[0]] = v }
        }
    }

    func of(_ t: Entry) -> [String: Decimal] {
        var tol: [String: Decimal] = [:]
        for p in t.postings {
            for c in [p.units != nil ? p.currency : nil, p.cost?.currency, p.price?.currency].compactMap({ $0 }) {
                if let v = defaults[c] { tol[c] = v }
            }
        }
        for p in t.postings {
            guard p.units != nil, let d = p.digits, d > 0, !p.interpolated, let c = p.currency else { continue }
            tol[c] = max(tol[c] ?? 0, multiplier * Decimal(sign: .plus, exponent: -d, significand: 1))
        }
        return tol
    }

    func of(_ t: Entry, _ c: String) -> Decimal { of(t)[c] ?? defaults["*"] ?? 0 }

    /// the residuals beyond what is allowed, per currency
    func unbalanced(_ t: Entry) -> [(String, Double)] {
        weightSums(t).filter { c, v in abs(v) > doubleOf(of(t, c)) + 1e-9 }
    }

    /// The decimal places Beancount rounds an amount it fills in to: those of twice the tolerance (0.005 → 0.01),
    /// half to even. Nil when there is no tolerance, or it isn't a short number like one a person would write: the
    /// amount is then filled in exactly (0.002 AAPL at 343.6395 USD leaves 0.687279 USD, not 0.69).
    func fillPlaces(_ t: Entry, _ c: String) -> Int? {
        let tol = of(t, c)
        guard tol > 0 else { return nil }
        let q = significantDigits(2 * tol)
        return q.digits < 5 ? q.places : nil
    }
}

/// `x` without its trailing zeros: how many significant digits it has and the decimal places it goes to
/// (0.010 → 1 digit, 2 places; 20 → 1 digit, -1 places)
func significantDigits(_ x: Decimal) -> (digits: Int, places: Int) {
    let parts = x.magnitude.description.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    var whole = parts[0], frac = parts.count > 1 ? parts[1] : ""
    while frac.hasSuffix("0") { frac.removeLast() }
    var places = frac.count
    if frac.isEmpty { while whole.count > 1 && whole.hasSuffix("0") { whole.removeLast(); places -= 1 } }
    return (max((whole + frac).drop { $0 == "0" }.count, 1), places)
}

/// sums of weights per currency, in first-seen order
func weightSums(_ t: Entry) -> [(String, Double)] {
    var order: [String] = []
    var sums: [String: Double] = [:]
    for p in t.postings {
        guard let w = weight(p) else { continue }
        if sums[w.c] == nil { order.append(w.c) }
        sums[w.c, default: 0] += w.n
    }
    return order.map { ($0, sums[$0]!) }
}

// fill one unknown per weight currency: missing units, price number or cost number
func interpolate(_ t: Entry, _ tolerance: BalanceTolerance, _ errors: inout [LedgerError]) {
    enum What { case units, cost, price }
    var unknown: [(p: Posting, what: What)] = []
    for p in t.postings {
        if p.units == nil { unknown.append((p, .units)) }
        else if let c = p.cost, c.number == nil, p.booked == nil, c.currency != nil { unknown.append((p, .cost)) }
        else if let pr = p.price, pr.raw == nil, pr.currency != nil { unknown.append((p, .price)) }
    }
    if unknown.isEmpty { return }
    var resOrder: [String] = []
    var res: [String: Double] = [:]
    // the residual again on the decimal numbers: a filled-in amount is rounded from it as Beancount does
    // (10.00 - 2.675 leaves 7.325, filled in as 7.32), or kept exact when there is nothing to round to
    var resD: [String: Decimal] = [:]
    for p in t.postings {
        guard let w = weight(p) else { continue }
        if res[w.c] == nil { resOrder.append(w.c) }
        res[w.c, default: 0] += w.n
        if let wd = decimalWeight(p) { resD[wd.c, default: 0] += wd.n }
    }
    func filled(_ c: String) -> (units: Double, digits: Int) {
        let x = -(resD[c] ?? decimalOf(res[c] ?? 0))
        // rounded, it keeps the places it was rounded to (-35.00, which noduplicates tells from -35)
        if let n = tolerance.fillPlaces(t, c) { return (doubleOf(rounded(x, n, .halfEven)), max(n, 0)) }
        return (doubleOf(x), max(significantDigits(x).places, 0))
    }
    let spread = unknown.filter { $0.what == .units && $0.p.currency == nil }
    let fixed = unknown.filter { !($0.what == .units && $0.p.currency == nil) }
    for u in fixed {
        let p = u.p
        let c: String
        switch u.what {
        case .units: c = p.cost?.currency ?? p.price?.currency ?? p.currency ?? ""
        case .cost: c = p.cost!.currency!
        case .price: c = p.price!.currency!
        }
        let r = res[c] ?? 0
        switch u.what {
        case .units:
            if p.cost != nil || p.price != nil { errors.append(LedgerError(entry: t, msg: tr("缺数量的分录不能带成本或价格", "A posting without units cannot have a cost or price"))); continue }
            (p.units, p.digits) = filled(c); p.interpolated = true
        case .cost, .price:
            // the residual over the units, in decimal as Beancount divides (1.001 / 11 is 0.091, not 0.0909999…);
            // zero units leave nothing to divide by
            guard let units = p.units, units != 0 else {
                errors.append(LedgerError(entry: t, msg: tr("数量为 0，无法推算单价或成本", "Zero units: the price or cost cannot be worked out")))
                continue
            }
            let total = abs(resD[c] ?? decimalOf(r))
            let per = doubleOf(total / abs(decimalOf(units)))
            if u.what == .cost {
                p.cost!.number = per; p.cost!.interpolated = true
            } else {
                p.price!.number = per
                p.price!.raw = p.price!.total ? doubleOf(total) : per
                p.price!.interpolated = true
            }
        }
        if res[c] == nil { resOrder.append(c) }
        res[c] = 0
        resD[c] = 0
    }
    if spread.count > 1 { errors.append(LedgerError(entry: t, msg: tr("只能有一条分录省略金额", "Only one posting may omit its amount"))) }
    if let m = spread.first?.p, let idx = t.postings.firstIndex(where: { $0 === m }) {
        let ccys = resOrder.filter { abs(res[$0] ?? 0) > EPS }
        let fill: [Posting] = ccys.map { c in
            let x = m.shallowCopy()
            (x.units, x.digits) = filled(c)
            x.currency = c
            x.interpolated = true
            return x
        }
        t.postings.replaceSubrange(idx...idx, with: fill)
    }
}

func matchLot(_ lot: Lot, _ spec: CostSpec) -> Bool {
    guard let lc = lot.cost else { return false }
    if let c = spec.currency, lc.currency != c { return false }
    if let pu = spec.perUnit, abs(lc.number - pu) > 1e-7 { return false }
    if let d = spec.date, lc.date != d { return false }
    if let l = spec.label, lc.label != l { return false }
    return true
}

func bookTxn(_ t: Entry, _ inv: inout [String: [Lot]], _ methodOf: (String) -> String, _ errors: inout [LedgerError]) {
    for p in t.postings {
        guard let spec = p.cost, let units = p.units, let currency = p.currency else { continue }
        let lots = inv[p.account] ?? []
        if inv[p.account] == nil { inv[p.account] = [] }
        let same = lots.filter { $0.currency == currency && $0.cost != nil }
        let reducing = same.contains { sign($0.units) == -sign(units) }
        let method = methodOf(p.account)
        if !reducing || method == "NONE" {
            // augmentation: resolve per-unit cost now (may still be missing → interpolation)
            if spec.perUnit != nil || spec.total != nil {
                spec.number = (spec.perUnit ?? 0) + (spec.total != nil ? spec.total! / abs(units) : 0)
            }
            spec.date = spec.date ?? t.date
            p.augment = true
            continue
        }
        // reduction
        var cands = same.filter { sign($0.units) == -sign(units) && matchLot($0, spec) }
        if cands.isEmpty {
            errors.append(LedgerError(entry: t, msg: tr("\(p.account) 找不到匹配的 \(currency) 批次 {\(spec.raw)}", "\(p.account): no \(currency) lot matches {\(spec.raw)}"), soft: true))
            continue
        }
        var need = abs(units)
        let avail = cands.reduce(0.0) { $0 + abs($1.units) }
        if avail + 1e-9 < need {
            errors.append(LedgerError(entry: t, msg: tr("\(p.account) 的 \(currency) 不够减：需要 \(fmtNum(need, 4))，只有 \(fmtNum(avail, 4))", "\(p.account): not enough \(currency) to reduce: need \(fmtNum(need, 4)), have \(fmtNum(avail, 4))"), soft: true))
        }
        if method == "STRICT" && cands.count > 1 && abs(avail - need) > 1e-9 {
            let costs = Set(cands.map { "\($0.cost!.number)|\($0.cost!.date ?? "")|\($0.cost!.label ?? "")" })
            if costs.count > 1 {
                errors.append(LedgerError(entry: t, msg: tr("\(p.account) 有多个 \(currency) 批次符合 {\(spec.raw)}，STRICT 无法确定，已按 FIFO 处理", "\(p.account): several \(currency) lots match {\(spec.raw)}; ambiguous under STRICT, booked as FIFO"), soft: true))
            }
        }
        if method == "LIFO" { cands.reverse() }
        else if method == "HIFO" {
            // stable sort, highest cost first
            cands = cands.enumerated().sorted { a, b in
                a.element.cost!.number != b.element.cost!.number ? a.element.cost!.number > b.element.cost!.number : a.offset < b.offset
            }.map { $0.element }
        }
        // AVERAGE: cost basis is the average of all matching lots; units come off oldest first
        var avg: Double? = nil
        if method == "AVERAGE" {
            let tot = cands.reduce(0.0) { $0 + abs($1.units) * $1.cost!.number }
            avg = tot / avail
        }
        var costSum = 0.0
        var booked: [Booked] = []
        for l in cands {
            if need <= 1e-12 { break }
            let take = min(need, abs(l.units))
            costSum += take * l.cost!.number
            need -= take
            booked.append(Booked(lot: l, take: take))
        }
        let took = abs(units) - need
        spec.number = avg ?? (took != 0 ? costSum / took : 0)
        if spec.currency == nil { spec.currency = cands[0].cost!.currency }
        p.booked = booked
    }
}

func applyInventory(_ t: Entry, _ inv: inout [String: [Lot]]) {
    for p in t.postings {
        guard let units = p.units, let currency = p.currency else { continue }
        var lots = inv[p.account] ?? []
        if let booked = p.booked {
            for b in booked { b.lot.units += sign(units) * b.take }
            lots.removeAll { abs($0.units) < 1e-9 }
            inv[p.account] = lots
            continue
        }
        if let c = p.cost, p.augment {
            let label = c.label
            if let hit = lots.first(where: { $0.currency == currency && $0.cost != nil && $0.cost!.number == c.number && $0.cost!.currency == c.currency && $0.cost!.date == c.date && $0.cost!.label == label }) {
                hit.units += units
            } else {
                lots.append(Lot(units: units, currency: currency, cost: LotCost(number: c.number ?? 0, currency: c.currency, date: c.date, label: label)))
            }
            inv[p.account] = lots
            continue
        }
        if let hit = lots.first(where: { $0.currency == currency && $0.cost == nil }) { hit.units += units }
        else { lots.append(Lot(units: units, currency: currency, cost: nil)) }
        inv[p.account] = lots
    }
}

// MARK: - loading

/// readFile(path) returns the text of a repo file (paths relative to the repo root); `listFiles` gives every file in
/// the repository, for includes with wildcards (`include "journals/*.bean"`)
public func loadLedger(root: String = "main.bean", listFiles: (() -> [String])? = nil, readFile: @escaping (String) throws -> String) -> Ledger {
    var entries: [Entry] = []
    var files: [String] = []
    var options: [String: [String?]] = [:]
    var plugins: [(String?, String?)] = []
    var errors: [LedgerError] = []
    var seen = Set<String>()
    func dirOf(_ p: String) -> String {
        guard let r = p.range(of: "/", options: .backwards) else { return "" }
        return String(p[..<r.upperBound])
    }
    func visit(_ path: String) {
        if seen.contains(path) { return }
        seen.insert(path)
        let text: String
        do { text = try readFile(path) } catch {
            errors.append(LedgerError(file: path, line: 0, msg: tr("读不到 \(path)：\(error.localizedDescription)", "Cannot read \(path): \(error.localizedDescription)")))
            return
        }
        files.append(path)
        let r = parseFile(text, file: path)
        entries.append(contentsOf: r.entries)
        errors.append(contentsOf: r.errors)
        plugins.append(contentsOf: r.plugins)
        for (k, v) in r.options { options[k, default: []].append(contentsOf: v) }
        for inc in r.includes {
            let target = normalizePath(inc.hasPrefix("/") ? String(inc.dropFirst()) : dirOf(path) + inc)
            if inc.contains("*") || inc.contains("?") || inc.contains("[") {
                // a wildcard: the matching files in name order, as Beancount does
                guard let all = listFiles?() else {
                    errors.append(softError(path, tr("无法展开 include \"\(inc)\"", "Cannot expand include \"\(inc)\"")))
                    continue
                }
                let hits = all.filter { globMatch(target, $0) }.sorted()
                if hits.isEmpty { errors.append(softError(path, tr("include \"\(inc)\" 没有匹配的文件", "include \"\(inc)\" matches no file"))) }
                for h in hits { visit(h) }
                continue
            }
            visit(target)
        }
    }
    visit(root)
    if let dirs = options["documents"]?.compactMap({ $0 }), !dirs.isEmpty {
        entries += documentsFromFolders(dirs, root: root, entries: entries, listFiles: listFiles, errors: &errors)
    }
    return build(entries, files: files, options: options, plugins: plugins, errors: errors)
}

/// `option "documents" "folder"`: a document for each file named `YYYY-MM-DD…` in a folder of the account's name
/// under it (`folder/Assets/Bank/HSBC/2025-06-28.statement.pdf`), as Beancount does. Folders are relative to the
/// main file's; accounts are those the ledger names anywhere. The documents point at their files from the main file.
func documentsFromFolders(_ dirs: [String], root: String, entries: [Entry], listFiles: (() -> [String])?, errors: inout [LedgerError]) -> [Entry] {
    guard let all = listFiles?() else {
        errors.append(softError(root, tr("无法列出文件，option \"documents\" 未生效", "Cannot list the files: option \"documents\" not applied")))
        return []
    }
    let base: String = { guard let r = root.range(of: "/", options: .backwards) else { return "" }; return String(root[..<r.upperBound]) }()
    var accounts = Set<String>()
    for e in entries {
        if let a = e.account { accounts.insert(a) }
        if let s = e.source { accounts.insert(s) }
        for p in e.postings { accounts.insert(p.account) }
    }
    let dated = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2}).(.*)$"#)
    var out: [Entry] = []
    for d in dirs {
        if d.hasPrefix("/") {
            errors.append(softError(root, tr("option \"documents\" 用的是电脑上的绝对路径 \(d)，App 只能找仓库里的文件夹", "option \"documents\" names a folder on a computer (\(d)); the app looks in the repository only")))
            continue
        }
        let dir = normalizePath(base + d)
        let pre = dir.isEmpty ? "" : dir + "/"
        let inDir = all.filter { $0.hasPrefix(pre) }.sorted()
        if inDir.isEmpty {
            errors.append(LedgerError(file: root, line: 0, msg: tr("票据文件夹 \(dir) 不存在", "Document folder \(dir) does not exist")))
            continue
        }
        for f in inDir {
            let rel = String(f.dropFirst(pre.count))
            guard let slash = rel.range(of: "/", options: .backwards) else { continue }
            let account = rel[..<slash.lowerBound].replacingOccurrences(of: "/", with: ":")
            let name = String(rel[slash.upperBound...])
            guard accounts.contains(account) else { continue }
            let ns = name as NSString
            guard let m = dated.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { continue }
            let date = "\(ns.substring(with: m.range(at: 1)))-\(ns.substring(with: m.range(at: 2)))-\(ns.substring(with: m.range(at: 3)))"
            guard let real = Day.date(date), Day.string(real) == date else {
                errors.append(LedgerError(file: root, line: 0, msg: tr("票据文件名的日期不对：\(name)", "Invalid date in a document's file name: \(name)")))
                continue
            }
            let e = Entry(type: .document, date: date, file: root, line: 0, startLine: -1, endLine: -1)
            e.account = account
            e.path = String(f.dropFirst(base.count))
            e.synthetic = true
            out.append(e)
        }
    }
    return out
}

private func softError(_ file: String, _ msg: String) -> LedgerError {
    var e = LedgerError(file: file, line: 0, msg: msg)
    e.soft = true
    return e
}

/// a shell wildcard against a repo path: `*` and `?` stay within one folder, `**` crosses folders, `[abc]` a set
public func globMatch(_ pattern: String, _ path: String) -> Bool {
    var re = "^"
    let cs = Array(pattern)
    var i = 0
    while i < cs.count {
        let c = cs[i]
        if c == "*" {
            if i + 1 < cs.count && cs[i + 1] == "*" {
                // "**/" also matches no folder at all
                if i + 2 < cs.count && cs[i + 2] == "/" { re += "(?:.*/)?"; i += 3; continue }
                re += ".*"; i += 2; continue
            }
            re += "[^/]*"
        } else if c == "?" {
            re += "[^/]"
        } else if c == "[" , let end = cs[i...].firstIndex(of: "]") {
            var set = String(cs[(i + 1)..<end]).replacingOccurrences(of: "\\", with: "\\\\")
            if set.hasPrefix("!") { set = "^" + set.dropFirst() }
            re += "[" + set + "]"
            i = end + 1
            continue
        } else {
            re += NSRegularExpression.escapedPattern(for: String(c))
        }
        i += 1
    }
    re += "$"
    return path.range(of: re, options: .regularExpression) != nil
}

public func normalizePath(_ p: String) -> String {
    var parts: [String] = []
    for s in p.split(separator: "/", omittingEmptySubsequences: false) {
        if s == ".." { if !parts.isEmpty { parts.removeLast() } }
        else if !s.isEmpty && s != "." { parts.append(String(s)) }
    }
    return parts.joined(separator: "/")
}

func typeOrder(_ t: EntryType) -> Int {
    switch t {
    case .open: return -2
    case .balance: return -1
    case .document: return 1
    case .close: return 2
    default: return 0
    }
}

public func build(_ input: [Entry], files: [String] = [], options: [String: [String?]] = [:], plugins: [(String?, String?)] = [], errors: [LedgerError] = []) -> Ledger {
    for (i, e) in input.enumerated() { e.seq = i }
    let entries = input.sorted { a, b in
        if a.date != b.date { return a.date < b.date }
        let oa = typeOrder(a.type), ob = typeOrder(b.type)
        if oa != ob { return oa < ob }
        return a.seq < b.seq
    }
    let L = Ledger()
    L.entries = entries; L.files = files; L.options = options; L.plugins = plugins; L.errors = errors
    if let b = options["operating_currency"]?.first, let bb = b { L.base = bb }
    let defaultBooking = ((options["booking_method"]?.first ?? nil) ?? "STRICT").uppercased()
    func methodOf(_ a: String) -> String { (L.accounts[a]?.booking ?? defaultBooking).uppercased() }

    var inv: [String: [Lot]] = [:]
    var bal: [String: [String: Double]] = [:]
    func add(_ a: String, _ c: String, _ n: Double) { bal[a, default: [:]][c, default: 0] += n }
    func subtotal(_ acct: String, _ c: String) -> Double {
        var s = 0.0
        let prefix = acct + ":"
        for (a, cs) in bal where a == acct || a.hasPrefix(prefix) { if let v = cs[c] { s += v } }
        return s
    }
    /// `filled`: it made up a difference (as in Beancount, a pad that never did is reported, even when an assertion
    /// followed it: the balance was right already, or a later pad took over)
    final class PadState { let pad: Entry; var used = Set<String>(); var filled = false; init(_ p: Entry) { pad = p } }
    var pending: [String: PadState] = [:]
    var padStates: [PadState] = []
    var synthetic: [Entry] = []
    let multiplier = Double((options["inferred_tolerance_multiplier"]?.first ?? nil) ?? "0.5") ?? 0.5
    let balanceTolerance = BalanceTolerance(options: options)

    for e in entries {
        switch e.type {
        case .open:
            let a = e.account ?? ""
            if let ex = L.accounts[a], !ex.implicit { L.errors.append(LedgerError(entry: e, msg: tr("重复开立账户：\(a)", "Account opened twice: \(a)"))) }
            L.accounts[a] = Account(name: a, open: e.date, close: nil, currencies: e.currencies, booking: e.booking, meta: e.meta)
        case .close:
            let a = e.account ?? ""
            if L.accounts[a] != nil { L.accounts[a]!.close = e.date }
            else { L.errors.append(LedgerError(entry: e, msg: tr("关闭了不存在的账户：\(a)", "Closing an account that was never opened: \(a)"))) }
        case .commodity: if let c = e.currency { L.commodities[c] = e.meta }
        case .price:
            L.prices.append(e)
            if e.number < 0 {
                L.errors.append(LedgerError(entry: e, msg: tr("价格不能为负：\(e.currency ?? "") \(fmtNum(e.number)) \(e.quote ?? "")",
                                                              "Negative prices are not allowed: \(e.currency ?? "") \(fmtNum(e.number)) \(e.quote ?? "")")))
            }
        case .event: L.events.append(e)
        case .note: L.notes.append(e)
        case .document: L.documents.append(e)
        case .pad:
            L.pads.append(e)
            let state = PadState(e)
            padStates.append(state)
            if let a = e.account { pending[a] = state }
        case .txn:
            let t = e
            if !t.bad.isEmpty { L.errors.append(LedgerError(entry: t, msg: tr("无法解析：\(t.bad.joined(separator: " | "))", "Cannot parse: \(t.bad.joined(separator: " | "))"))) }
            for p in t.postings {
                if let pr = p.price, (pr.number ?? pr.raw ?? 0) < 0 {
                    L.errors.append(LedgerError(entry: t, msg: tr("\(p.account) 的价格不能为负", "\(p.account): negative prices are not allowed")))
                }
            }
            bookTxn(t, &inv, methodOf, &L.errors)
            interpolate(t, balanceTolerance, &L.errors)
            for p in t.postings {
                if let acc = L.accounts[p.account] {
                    L.errors += accountUseErrors(t, p, acc)
                } else {
                    L.accounts[p.account] = Account(name: p.account, implicit: true)
                    var e = LedgerError(entry: t, msg: tr("账户未开立：\(p.account)", "Account not opened: \(p.account)"))
                    e.accountMisuse = true
                    L.errors.append(e)
                }
            }
            for (c, v) in balanceTolerance.unbalanced(t) {
                L.errors.append(LedgerError(entry: t, msg: tr("不平衡 \(fmtNum(v, 4)) \(c)", "Unbalanced by \(fmtNum(v, 4)) \(c)")))
            }
            applyInventory(t, &inv)
            for p in t.postings { if let u = p.units, let c = p.currency { add(p.account, c, u) } }
            L.txns.append(t)
        case .balance:
            L.balances.append(e)
            let acct = e.account ?? "", ccy = e.currency ?? ""
            var got = subtotal(acct, ccy)
            let tol = e.tolerance ?? (e.digits > 0 ? pow(10, -Double(e.digits)) * multiplier * 2 : 0)
            if let pd = pending[acct], !pd.used.contains(ccy) {
                pd.used.insert(ccy)
                let diff = e.number - got
                if abs(diff) > tol + 1e-9 {
                    let t = pd.pad.copyBase(as: .txn)
                    t.meta = Meta()
                    t.flag = "P"
                    t.narration = "(Padding inserted for Balance of \(fmtNum(e.number)) \(ccy) for difference \(fmtNum(diff)) \(ccy))"
                    t.synthetic = true
                    t.src = pd.pad.src
                    let a = Posting(account: pd.pad.account ?? ""); a.units = roundTo(diff, 8); a.currency = ccy; a.digits = e.digits
                    let b = Posting(account: pd.pad.source ?? ""); b.units = roundTo(-diff, 8); b.currency = ccy; b.digits = e.digits
                    t.postings = [a, b]
                    for p in t.postings { add(p.account, ccy, p.units!) }
                    applyInventory(t, &inv)
                    synthetic.append(t)
                    pd.filled = true
                    got = subtotal(acct, ccy)
                }
            }
            let ok = abs(got - e.number) <= tol + 1e-9
            L.balanceResults.append(BalanceResult(entry: e, got: got, ok: ok, diff: got - e.number))
            if !ok {
                L.errors.append(LedgerError(entry: e, msg: tr("余额断言失败：\(acct) 应为 \(fmtNum(e.number)) \(ccy)，实际 \(fmtNum(got))（差 \(fmtNum(got - e.number))）", "Balance failed: \(acct) expected \(fmtNum(e.number)) \(ccy), got \(fmtNum(got)) (off by \(fmtNum(got - e.number)))")))
            }
        default: break
        }
    }
    if !synthetic.isEmpty {
        L.txns.append(contentsOf: synthetic)
        L.txns = L.txns.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if x.date != y.date { return x.date < y.date }
            let sx = x.synthetic ? Int.max : x.seq, sy = y.synthetic ? Int.max : y.seq
            if sx != sy { return sx < sy }
            return a.offset < b.offset
        }.map { $0.element }
    }
    for st in padStates where !st.filled {
        let a = st.pad.account ?? ""
        L.errors.append(LedgerError(entry: st.pad, msg: tr("pad \(a) 没有生效：之后没有需要它补差额的余额断言",
                                                          "pad \(a) has no effect: no balance assertion after it needed padding")))
    }
    for (i, t) in L.txns.enumerated() { t.id = i }
    L.final = bal
    L.inventory = inv
    runPlugins(L)
    buildRates(L)
    return L
}

// MARK: - currency conversion

func buildRates(_ L: Ledger) {
    struct Pair { let date: String; let base: String; let quote: String; let rate: Double }
    var pairs: [Pair] = []
    // (the prices implicit_prices adds come from the postings below)
    // a negative price is an error, never a rate
    for p in L.prices where !p.synthetic && p.number > 0 { pairs.append(Pair(date: p.date, base: p.currency ?? "", quote: p.quote ?? "", rate: p.number)) }
    for t in L.txns {
        for p in t.postings {
            // a per-unit price, or a total one (@@) over the units
            if let pr = p.price, let c = p.currency, let pc = pr.currency, c != pc,
               (pr.number ?? pr.raw ?? 0) >= 0,
               let n = pr.number ?? (pr.total ? pr.raw.flatMap { r in p.units.flatMap { u in u != 0 ? abs(r) / abs(u) : nil } } : nil), n != 0 {
                pairs.append(Pair(date: t.date, base: c, quote: pc, rate: n))
            }
            if let cost = p.cost, let n = cost.number, n != 0, let c = p.currency, let cc = cost.currency, c != cc {
                pairs.append(Pair(date: t.date, base: c, quote: cc, rate: n))
            }
        }
    }
    pairs = pairs.enumerated().sorted { a, b in a.element.date != b.element.date ? a.element.date < b.element.date : a.offset < b.offset }.map { $0.element }
    var latestKeys: [String] = []
    var latest: [String: Double] = [:]
    var series: [String: [RatePoint]] = [:]
    let base = L.base
    func solve() -> [(String, Double)] {
        var v: [String: Double] = [base: 1]
        var order = [base]
        var changed = true
        while changed {
            changed = false
            for k in latestKeys {
                let parts = k.components(separatedBy: ">")
                let a = parts[0], b = parts[1]
                if v[b] != nil && v[a] == nil { v[a] = latest[k]! * v[b]!; order.append(a); changed = true }
                else if v[a] != nil && v[b] == nil { v[b] = v[a]! / latest[k]!; order.append(b); changed = true }
            }
        }
        return order.map { ($0, v[$0]!) }
    }
    var i = 0
    while i < pairs.count {
        let d = pairs[i].date
        while i < pairs.count && pairs[i].date == d {
            let p = pairs[i]; i += 1
            if p.rate != 0 {
                // one rate per pair of currencies, whichever way it was written: the latest wins
                // (CNY @ 1.09 HKD after a price HKD 0.926 CNY means 1 HKD = 0.914 CNY from then on, as in Beancount)
                let (a, b, r) = p.base < p.quote ? (p.base, p.quote, p.rate) : (p.quote, p.base, 1 / p.rate)
                let k = a + ">" + b
                if latest[k] == nil { latestKeys.append(k) }
                latest[k] = r
            }
        }
        for (c, x) in solve() { series[c, default: []].append(RatePoint(date: d, v: x)) }
    }
    L.rates = series
}

public func toCNY(_ L: Ledger, _ n: Double, _ c: String, _ date: String? = nil) -> Double? {
    if c == L.base { return n }
    guard let s = L.rates[c], !s.isEmpty else { return nil }
    var lo = 0, hi = s.count - 1, best = 0
    if let date = date {
        while lo <= hi {
            let m = (lo + hi) >> 1
            if s[m].date <= date { best = m; lo = m + 1 } else { hi = m - 1 }
        }
    } else { best = hi }
    return n * s[best].v
}

// MARK: - helpers

public func fmtNum(_ n: Double?, _ d: Int = 2) -> String {
    guard let n = n, !n.isNaN else { return "" }
    let s = toFixed(abs(n), d)
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    let ip = String(parts[0])
    var grouped = ""
    for (k, ch) in ip.enumerated() {
        if k > 0 && (ip.count - k) % 3 == 0 { grouped.append(",") }
        grouped.append(ch)
    }
    return (n < -EPS ? "-" : "") + grouped + (parts.count > 1 ? "." + parts[1] : "")
}

public func balancesAt(_ L: Ledger, _ date: String?) -> [String: [String: Double]] {
    var bal: [String: [String: Double]] = [:]
    for t in L.txns {
        if let d = date, t.date > d { break }
        for p in t.postings { if let u = p.units, let c = p.currency { bal[p.account, default: [:]][c, default: 0] += u } }
    }
    return bal
}

// MARK: - checking text before it is written

public struct CheckResult {
    public var ok: Bool
    public var errors: [LedgerError]
    public var warnings: [LedgerError]
    public var entries: [Entry]
    public var msg: String?
}

public func checkText(_ text: String, _ L: Ledger?) -> CheckResult {
    let r = parseFile(text, file: "draft")
    var errors = r.errors
    if !r.includes.isEmpty || !r.options.isEmpty || !r.plugins.isEmpty { errors.append(LedgerError(file: nil, line: nil, msg: tr("include / option / plugin 请直接改 main.bean", "Edit include / option / plugin directly in main.bean"))) }
    // the lots of the accounts these entries post to (a copy: booking takes from them); the others aren't touched
    var inv: [String: [Lot]] = [:]
    for a in Set(r.entries.flatMap { $0.postings.map { $0.account } }) {
        if let lots = L?.inventory[a] { inv[a] = lots.map { $0.clone() } }
    }
    let defaultBooking = ((L?.options["booking_method"]?.first ?? nil) ?? "STRICT")
    let balanceTolerance = BalanceTolerance(options: L?.options ?? [:])
    func methodOf(_ a: String) -> String { (L?.accounts[a]?.booking ?? defaultBooking).uppercased() }
    func opened(_ a: String) -> Bool { r.entries.contains { $0.type == .open && $0.account == a } }
    for e in r.entries {
        if e.type == .txn {
            if let b = e.bad.first { errors.append(LedgerError(entry: e, msg: tr("无法解析：" + b, "Cannot parse: " + b))) }
            if e.postings.isEmpty { errors.append(LedgerError(entry: e, msg: tr("交易至少需要一条分录", "A transaction needs at least one posting"))) }
            var errs: [LedgerError] = []
            bookTxn(e, &inv, methodOf, &errs)
            interpolate(e, balanceTolerance, &errs)
            errors.append(contentsOf: errs)
            for (c, v) in balanceTolerance.unbalanced(e) {
                errors.append(LedgerError(entry: e, msg: tr("不平衡：差 \(fmtNum(v, 4)) \(c)", "Unbalanced by \(fmtNum(v, 4)) \(c)")))
            }
            for p in e.postings where p.account == personalAccount && postingPerson(p) == nil {
                errors.append(LedgerError(entry: e, msg: tr("个人往来没有注明是谁（person:）", "Personal receivable without a person (person:)"), soft: true))
            }
            if let L = L {
                for p in e.postings {
                    if let acc = L.accounts[p.account] {
                        errors += accountUseErrors(e, p, acc)
                    } else if !opened(p.account) {
                        var err = LedgerError(entry: e, msg: tr("账户未开立：" + p.account, "Account not opened: " + p.account))
                        err.accountMisuse = true
                        errors.append(err)
                    }
                }
            }
            applyInventory(e, &inv)
        } else if [.balance, .pad, .note, .document, .close].contains(e.type) {
            if let L = L {
                for a in [e.account, e.source].compactMap({ $0 }) where L.accounts[a] == nil && !opened(a) {
                    errors.append(LedgerError(entry: e, msg: tr("账户未开立：" + a, "Account not opened: " + a)))
                }
            }
        } else if e.type == .open, let L = L, let a = e.account, let ex = L.accounts[a], !ex.implicit {
            errors.append(LedgerError(entry: e, msg: tr("账户已经开立过：" + a, "Account already opened: " + a)))
        }
    }
    if r.entries.isEmpty && errors.isEmpty { errors.append(LedgerError(file: nil, line: nil, msg: tr("没有可以写入的内容", "Nothing to write"))) }
    let hard = errors.filter { !$0.soft }
    return CheckResult(ok: hard.isEmpty, errors: hard, warnings: errors.filter { $0.soft }, entries: r.entries, msg: hard.first?.msg)
}
