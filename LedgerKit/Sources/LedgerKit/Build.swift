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

/// per-currency tolerance inferred from the precision of the numbers in the txn
func tolerances(_ t: Entry) -> [String: Double] {
    var tol: [String: Double] = [:]
    for p in t.postings {
        guard p.units != nil, let d = p.digits, !p.interpolated, let c = p.currency else { continue }
        let v = 0.5 * pow(10, -Double(d))
        tol[c] = max(tol[c] ?? 0, v)
    }
    return tol
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
func interpolate(_ t: Entry, _ errors: inout [LedgerError]) {
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
    var dig: [String: Int] = [:]
    for p in t.postings {
        guard let w = weight(p) else { continue }
        if res[w.c] == nil { resOrder.append(w.c) }
        res[w.c, default: 0] += w.n
        if let d = p.digits, p.currency == w.c { dig[w.c] = max(dig[w.c] ?? 0, d) }
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
            p.units = roundTo(-r, min(dig[c] ?? 2, 8)); p.interpolated = true; p.digits = dig[c] ?? 2
        case .cost:
            p.cost!.number = abs(-r / p.units!); p.cost!.interpolated = true
        case .price:
            p.price!.number = abs(-r / p.units!)
            p.price!.raw = p.price!.total ? abs(r) : p.price!.number
            p.price!.interpolated = true
        }
        if res[c] == nil { resOrder.append(c) }
        res[c] = 0
    }
    if spread.count > 1 { errors.append(LedgerError(entry: t, msg: tr("只能有一条分录省略金额", "Only one posting may omit its amount"))) }
    if let m = spread.first?.p, let idx = t.postings.firstIndex(where: { $0 === m }) {
        let ccys = resOrder.filter { abs(res[$0] ?? 0) > EPS }
        let fill: [Posting] = ccys.map { c in
            let x = m.shallowCopy()
            x.units = roundTo(-(res[c] ?? 0), min(dig[c] ?? 2, 8))
            x.currency = c
            x.digits = dig[c] ?? 2
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

/// readFile(path) returns the text of a repo file (paths relative to the repo root)
public func loadLedger(root: String = "main.bean", readFile: @escaping (String) throws -> String) -> Ledger {
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
            if inc.contains("*") || inc.contains("?") { continue } // globs are not resolvable over the API
            visit(normalizePath(inc.hasPrefix("/") ? String(inc.dropFirst()) : dirOf(path) + inc))
        }
    }
    visit(root)
    return build(entries, files: files, options: options, plugins: plugins, errors: errors)
}

public func normalizePath(_ p: String) -> String {
    var parts: [String] = []
    for s in p.split(separator: "/", omittingEmptySubsequences: false) {
        if s == ".." { if !parts.isEmpty { parts.removeLast() } }
        else if !s.isEmpty && s != "." { parts.append(String(s)) }
    }
    return parts.joined(separator: "/")
}

private func typeOrder(_ t: EntryType) -> Int {
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
    final class PadState { let pad: Entry; var used = Set<String>(); init(_ p: Entry) { pad = p } }
    var pending: [String: PadState] = [:]
    var synthetic: [Entry] = []
    let multiplier = Double((options["inferred_tolerance_multiplier"]?.first ?? nil) ?? "0.5") ?? 0.5

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
        case .price: L.prices.append(e)
        case .event: L.events.append(e)
        case .note: L.notes.append(e)
        case .document: L.documents.append(e)
        case .pad:
            L.pads.append(e)
            if let a = e.account { pending[a] = PadState(e) }
        case .txn:
            let t = e
            if !t.bad.isEmpty { L.errors.append(LedgerError(entry: t, msg: tr("无法解析：\(t.bad.joined(separator: " | "))", "Cannot parse: \(t.bad.joined(separator: " | "))"))) }
            bookTxn(t, &inv, methodOf, &L.errors)
            interpolate(t, &L.errors)
            for p in t.postings {
                if let acc = L.accounts[p.account] {
                    if let o = acc.open, t.date < o { L.errors.append(LedgerError(entry: t, msg: tr("\(p.account) 在 \(o) 才开立", "\(p.account) is not open until \(o)"))) }
                    else if let c = acc.close, t.date > c { L.errors.append(LedgerError(entry: t, msg: tr("\(p.account) 已于 \(c) 关闭", "\(p.account) was closed on \(c)"))) }
                    if !acc.currencies.isEmpty, let c = p.currency, !acc.currencies.contains(c) { L.errors.append(LedgerError(entry: t, msg: tr("\(p.account) 不允许 \(c)", "\(p.account) does not allow \(c)"))) }
                } else {
                    L.accounts[p.account] = Account(name: p.account, implicit: true)
                    L.errors.append(LedgerError(entry: t, msg: tr("账户未开立：\(p.account)", "Account not opened: \(p.account)")))
                }
            }
            let tol = tolerances(t)
            for (c, v) in weightSums(t) where abs(v) > (tol[c] ?? 0.005) + 1e-9 {
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
    for pd in L.pads {
        let a = pd.account ?? ""
        if pending[a] == nil || (pending[a]!.pad === pd && pending[a]!.used.isEmpty) {
            L.errors.append(LedgerError(entry: pd, msg: tr("pad \(a) 之后没有余额断言，没有生效", "pad \(a) has no following balance assertion and has no effect")))
        }
    }
    for (i, t) in L.txns.enumerated() { t.id = i }
    L.final = bal
    L.inventory = inv
    buildRates(L)
    return L
}

// MARK: - currency conversion

func buildRates(_ L: Ledger) {
    struct Pair { let date: String; let base: String; let quote: String; let rate: Double }
    var pairs: [Pair] = []
    for p in L.prices { pairs.append(Pair(date: p.date, base: p.currency ?? "", quote: p.quote ?? "", rate: p.number)) }
    for t in L.txns {
        for p in t.postings {
            if let pr = p.price, let n = pr.number, n != 0, let c = p.currency, let pc = pr.currency, c != pc {
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
                let k = p.base + ">" + p.quote
                if latest[k] == nil { latestKeys.append(k) }
                latest[k] = p.rate
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
    var inv: [String: [Lot]] = [:]
    for (a, lots) in L?.inventory ?? [:] { inv[a] = lots.map { $0.clone() } }
    let defaultBooking = ((L?.options["booking_method"]?.first ?? nil) ?? "STRICT")
    func methodOf(_ a: String) -> String { (L?.accounts[a]?.booking ?? defaultBooking).uppercased() }
    func opened(_ a: String) -> Bool { r.entries.contains { $0.type == .open && $0.account == a } }
    for e in r.entries {
        if e.type == .txn {
            if let b = e.bad.first { errors.append(LedgerError(entry: e, msg: tr("无法解析：" + b, "Cannot parse: " + b))) }
            if e.postings.isEmpty { errors.append(LedgerError(entry: e, msg: tr("交易至少需要一条分录", "A transaction needs at least one posting"))) }
            var errs: [LedgerError] = []
            bookTxn(e, &inv, methodOf, &errs)
            interpolate(e, &errs)
            errors.append(contentsOf: errs)
            let tol = tolerances(e)
            for (c, v) in weightSums(e) where abs(v) > (tol[c] ?? 0.005) + 1e-9 {
                errors.append(LedgerError(entry: e, msg: tr("不平衡：差 \(fmtNum(v, 4)) \(c)", "Unbalanced by \(fmtNum(v, 4)) \(c)")))
            }
            if let L = L {
                for p in e.postings where L.accounts[p.account] == nil && !opened(p.account) {
                    errors.append(LedgerError(entry: e, msg: tr("账户未开立：" + p.account, "Account not opened: " + p.account)))
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
