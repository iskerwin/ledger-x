import Foundation

// MARK: - Beancount plugins the app runs itself
//
// Only what main.bean declares (`plugin "beancount.plugins.…"`) runs, in the order declared, after booking — as
// bean-check does. Each one does what the Beancount 2.3.6 plugin of the same name does, checked against it in
// PluginTests (tools/plugins_expected.py). Other plugins are not run: `unexecutedPlugins` names them.

public enum BuiltinPlugin: String, CaseIterable {
    case checkCommodity = "beancount.plugins.check_commodity"
    case implicitPrices = "beancount.plugins.implicit_prices"
    case noDuplicates = "beancount.plugins.noduplicates"
    case leafOnly = "beancount.plugins.leafonly"
}

/// something the app can put right for an error with one tap
public enum LedgerFix: Equatable {
    /// add `commodity <currency>` (check_commodity)
    case declareCommodity(String)
}

/// the plugins main.bean declares that the app does not run, each once, in the order declared
public func unexecutedPlugins(_ L: Ledger) -> [String] {
    var seen = Set<String>(), out: [String] = []
    for (name, _) in L.plugins {
        guard let n = name, BuiltinPlugin(rawValue: n) == nil, seen.insert(n).inserted else { continue }
        out.append(n)
    }
    return out
}

func runPlugins(_ L: Ledger) {
    for (name, _) in L.plugins {
        guard let n = name, let p = BuiltinPlugin(rawValue: n) else { continue }
        switch p {
        case .checkCommodity: checkCommodity(L)
        case .implicitPrices: implicitPrices(L)
        case .noDuplicates: noDuplicates(L)
        case .leafOnly: leafOnly(L)
        }
    }
}

// MARK: check_commodity: every currency in use has a commodity directive

private func checkCommodity(_ L: Ledger) {
    // the first entry each currency turns up in, in the ledger's order (Beancount reports them in that order)
    var first: [String: Entry] = [:], order: [String] = []
    func seen(_ c: String?, _ e: Entry) {
        guard let c = c, !c.isEmpty, first[c] == nil else { return }
        first[c] = e; order.append(c)
    }
    for e in L.entries {
        switch e.type {
        case .open: for c in e.currencies { seen(c, e) }
        case .txn:
            for p in e.postings {
                seen(p.currency, e)
                if let c = p.cost?.currency { seen(c, e) }
                for b in p.booked ?? [] { seen(b.lot.cost?.currency, e) }
                seen(p.price?.currency, e)
            }
        case .balance: seen(e.currency, e)
        case .price: seen(e.currency, e); seen(e.quote, e)
        default: break
        }
    }
    // and the prices implicit_prices has added (made from the same postings, so nothing new in practice)
    for e in L.prices where e.synthetic { seen(e.currency, e); seen(e.quote, e) }
    for c in order where L.commodities[c] == nil {
        var err = LedgerError(entry: first[c], msg: tr("缺少 commodity 声明：\(c)（check_commodity）", "Missing commodity directive for \(c) (check_commodity)"))
        err.fix = .declareCommodity(c)
        L.errors.append(err)
    }
}

// MARK: implicit_prices: a price for each `@` price, and for each cost a lot is bought at

private func implicitPrices(_ L: Ledger) {
    var out: [Entry] = []
    var seen = Set<String>()
    let explicit = Set(L.prices.map { ObjectIdentifier($0) })
    // explicit prices and the new ones in the ledger's order, each new one after its transaction
    for e in L.entries {
        if e.type == .price, explicit.contains(ObjectIdentifier(e)) { out.append(e); continue }
        guard e.type == .txn else { continue }
        for p in e.postings {
            guard let c = p.currency else { continue }
            var n: Double?, q: String?
            if let pr = p.price, let pc = pr.currency {
                n = pr.number ?? (pr.total ? pr.raw.flatMap { r in p.units.flatMap { u in u != 0 ? abs(r) / abs(u) : nil } } : nil)
                q = pc
            } else if let cost = p.cost, p.augment, p.booked == nil, let cn = cost.number, let cc = cost.currency {
                // a lot bought (not one sold from)
                n = cn; q = cc
            }
            guard let num = n, let quote = q else { continue }
            let key = [e.date, c, numberKey(num), quote].joined(separator: "|")
            guard seen.insert(key).inserted else { continue }
            let x = Entry(type: .price, date: e.date, file: e.file, line: e.line, startLine: e.startLine, endLine: e.endLine)
            x.currency = c; x.number = num; x.quote = quote; x.synthetic = true
            x.meta["__implicit_prices__"] = .string(p.price != nil ? "from_price" : "from_cost")
            out.append(x)
        }
    }
    L.prices = out
}

// MARK: noduplicates: no two directives exactly alike

private func noDuplicates(_ L: Ledger) {
    var last: [String: Entry] = [:]
    // in Beancount's order — by date, kind and line number, whatever the file — with the prices implicit_prices
    // made (duplicate prices are allowed, as in Beancount); the later of two is the one reported
    let all = (L.entries + L.prices.filter { $0.synthetic }).enumerated().sorted { a, b in
        let x = a.element, y = b.element
        if x.date != y.date { return x.date < y.date }
        let ox = typeOrder(x.type), oy = typeOrder(y.type)
        if ox != oy { return ox < oy }
        if x.line != y.line { return x.line < y.line }
        return a.offset < b.offset
    }.map { $0.element }
    for e in all {
        let k = entryKey(e)
        if let o = last[k], e.type != .price {
            L.errors.append(LedgerError(entry: e, msg: tr("与 \(o.file):\(o.line) 的指令完全相同（noduplicates）",
                                                         "Exactly the same as the directive at \(o.file):\(o.line) (noduplicates)")))
        }
        last[k] = e
    }
}

/// a number as Beancount writes it out: as many decimals as it was written with
private func written(_ n: Double, _ digits: Int?) -> String {
    if let d = digits, d > 0 { return String(format: "%.\(d)f", n) }
    return numberKey(n)
}

private func numberKey(_ n: Double) -> String {
    let r = (n * 1e10).rounded() / 1e10
    return jsNumberString(r == 0 ? 0 : r)
}

/// what makes two directives the same for noduplicates: every field but the metadata (and the order of the
/// postings, tags, links, an open's currencies and a custom's values)
func entryKey(_ e: Entry) -> String {
    var f: [String] = [e.type.rawValue, e.date]
    switch e.type {
    case .txn:
        f += [e.flag, e.hasPayee ? e.payee : "\u{0}", e.narration, e.tags.sorted().joined(separator: ","), e.links.sorted().joined(separator: ",")]
        f += e.postings.map { p in
            var s = [p.flag ?? "", p.account, p.units.map { written($0, p.digits) } ?? "", p.currency ?? ""]
            if let c = p.cost {
                if let b = p.booked, !b.isEmpty {
                    s += b.map { x in [numberKey(x.take), x.lot.cost.map { [numberKey($0.number), $0.currency ?? "", $0.date ?? "", $0.label ?? ""].joined(separator: "/") } ?? ""].joined(separator: "@") }
                } else {
                    s += ["{", c.number.map(numberKey) ?? "", c.currency ?? "", c.date ?? "", c.label ?? ""]
                }
            }
            if let pr = p.price { s += ["@", pr.number.map(numberKey) ?? pr.raw.map(numberKey) ?? "", pr.currency ?? ""] }
            return s.joined(separator: "\u{1}")
        }.sorted()
    case .open: f += [e.account ?? "", e.currencies.sorted().joined(separator: ","), e.booking ?? ""]
    case .close: f += [e.account ?? ""]
    case .commodity: f += [e.currency ?? ""]
    case .balance: f += [e.account ?? "", written(e.number, e.digits), e.currency ?? "", e.tolerance.map(numberKey) ?? ""]
    case .pad: f += [e.account ?? "", e.source ?? ""]
    case .note: f += [e.account ?? "", e.comment ?? ""]
    case .document: f += [e.account ?? "", e.path ?? "", e.tags.sorted().joined(separator: ","), e.links.sorted().joined(separator: ",")]
    case .event: f += [e.name ?? "", e.eventDescription ?? ""]
    case .query: f += [e.name ?? "", e.query ?? ""]
    case .price: f += [e.currency ?? "", numberKey(e.number), e.quote ?? ""]
    case .custom: f += [e.name ?? ""] + e.values.map { $0.display }.sorted()
    }
    return f.joined(separator: "\u{2}")
}

// MARK: leafonly: nothing booked to an account that has accounts under it

private func leafOnly(_ L: Ledger) {
    // the accounts each directive touches, as Beancount's realization has them (an open counts too)
    var touched = Set<String>()
    for e in L.entries {
        switch e.type {
        case .txn: for p in e.postings { touched.insert(p.account) }
        case .open, .close, .balance, .note, .document: if let a = e.account { touched.insert(a) }
        case .pad: if let a = e.account { touched.insert(a) }; if let s = e.source { touched.insert(s) }
        default: break
        }
    }
    var parents = Set<String>()
    for a in touched {
        var parts = a.split(separator: ":").map(String.init)
        while parts.count > 1 { parts.removeLast(); parents.insert(parts.joined(separator: ":")) }
    }
    let opens = Dictionary(L.entries.filter { $0.type == .open }.compactMap { e in e.account.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
    for a in touched.intersection(parents).sorted() {
        L.errors.append(LedgerError(entry: opens[a], msg: tr("\(a) 下面还有子账户，不能直接记账（leafonly）", "\(a) has accounts under it and cannot be booked to directly (leafonly)")))
    }
}
