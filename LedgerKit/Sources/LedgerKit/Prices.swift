import Foundation

/// Prices from Yahoo Finance. A commodity can say where its price comes from with bean-price's
/// metadata, e.g.  2025-01-01 commodity VOO  /  price: "USD:yahoo/VOO"  (or "CNY:yahoo/510300.SS").
/// Without it: currencies use "USDCNY=X", anything else its own name as the ticker.
public enum PriceFetch {
    /// the Yahoo symbol for commodity `c` quoted in `q`, and whether the quote is inverted
    public static func symbol(_ c: String, _ q: String, _ L: Ledger) -> (String, Bool) {
        if let e = L.entries.last(where: { $0.type == .commodity && $0.currency == c }), case .string(let spec)? = e.meta["price"] {
            for part in spec.split(whereSeparator: { $0 == " " || $0 == "," }) {
                let kv = part.split(separator: ":", maxSplits: 1).map(String.init)
                guard kv.count == 2, kv[0] == q else { continue }
                var src = kv[1]
                var inverted = false
                if src.hasPrefix("^") { inverted = true; src.removeFirst() }
                let sp = src.split(separator: "/", maxSplits: 1).map(String.init)
                if sp.count == 2, sp[0].lowercased().contains("yahoo") { return (sp[1], inverted) }
            }
        }
        let fiat: Set<String> = ["USD", "HKD", "EUR", "GBP", "JPY", "SGD", "AUD", "CAD", "CHF", "MOP", "TWD", "KRW", "CNY", "NZD", "THB", "MYR"]
        let isCurrency = fiat.contains(c)
        return isCurrency ? ("\(c)\(q)=X", false) : (c, false)
    }

    public struct Quote: Sendable { public let price: Double; public let currency: String? }

    public static func fetch(_ symbol: String) async throws -> Quote {
        let s = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(s)?interval=1d&range=5d") else { throw URLError(.badURL) }
        var r = URLRequest(url: url)
        r.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 15
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let res = ((o["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let meta = res["meta"] as? [String: Any],
              let p = (meta["regularMarketPrice"] as? Double) ?? (meta["previousClose"] as? Double) else {
            throw URLError(.cannotParseResponse)
        }
        return Quote(price: p, currency: meta["currency"] as? String)
    }

    public struct Candle: Identifiable, Sendable { public let date: Date; public let open, high, low, close: Double; public var id: Date { date } }

    /// daily / weekly / monthly candles for a chart (Yahoo's range: 1mo 3mo 6mo 1y 5y; interval: 1d 1wk 1mo)
    public static func candles(_ symbol: String, range: String, interval: String) async throws -> [Candle] {
        let s = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(s)?interval=\(interval)&range=\(range)") else { throw URLError(.badURL) }
        var r = URLRequest(url: url)
        r.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 20
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let res = ((o["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let ts = res["timestamp"] as? [Double],
              let q = ((res["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first else {
            throw URLError(.cannotParseResponse)
        }
        func col(_ k: String) -> [Double?] { (q[k] as? [Any] ?? []).map { $0 as? Double } }
        let op = col("open"), hi = col("high"), lo = col("low"), cl = col("close")
        var out: [Candle] = []
        for (i, t) in ts.enumerated() where i < op.count && i < hi.count && i < lo.count && i < cl.count {
            guard let a = op[i], let h = hi[i], let l = lo[i], let c = cl[i] else { continue }
            out.append(Candle(date: Date(timeIntervalSince1970: t), open: a, high: h, low: l, close: c))
        }
        // London prices come in pence
        if (res["meta"] as? [String: Any])?["currency"] as? String == "GBp" {
            out = out.map { Candle(date: $0.date, open: $0.open / 100, high: $0.high / 100, low: $0.low / 100, close: $0.close / 100) }
        }
        return out
    }

    /// prices for the rows of the price sheet; failures are left out
    public static func fetchAll(_ items: [PriceItem], _ L: Ledger) async -> [String: Double] {
        var out: [String: Double] = [:]
        await withTaskGroup(of: (String, Double?).self) { g in
            for it in items {
                let (sym, inv) = symbol(it.c, it.q, L)
                g.addTask {
                    guard let qt = try? await fetch(sym), qt.price > 0 else { return (it.id, nil) }
                    // Yahoo reports London prices in pence
                    var p = qt.price
                    if qt.currency == "GBp" { p /= 100 }
                    return (it.id, inv ? 1 / p : p)
                }
            }
            for await (id, p) in g { if let p = p { out[id] = p } }
        }
        return out
    }

    public static func line(_ date: String, _ c: String, _ q: String, _ v: Double) -> String {
        "\(date) price \(c)" + String(repeating: " ", count: max(1, 26 - c.count)) + jsNumberString(roundTo(v, v < 10 ? 6 : 4)) + " " + q
    }
}

/// one row of 更新价格: a commodity or currency and the currency it is quoted in, with its latest price
public struct PriceItem: Identifiable, Hashable, Sendable {
    public var id: String { c + "/" + q }
    public let c: String
    public let q: String
    public let last: Double?
    public let date: String?
}

/// what 更新价格 offers: everything held at cost, the foreign currencies held, then anything else already priced
public func priceItems(_ L: Ledger) -> [PriceItem] {
    var seen = Set<String>()
    var out: [PriceItem] = []
    func add(_ c: String, _ q: String) {
        guard c != q, seen.insert(c + "/" + q).inserted else { return }
        let p = latestPrice(L, c, q)
        out.append(PriceItem(c: c, q: q, last: p?.number, date: p?.date))
    }
    let held = holdings(L)
    for h in held { add(h.c, h.q) }
    // foreign currencies held in assets or liabilities
    for (a, cs) in L.final.sorted(by: { $0.key < $1.key }) where a.hasPrefix("Assets") || a.hasPrefix("Liabilities") {
        for (c, n) in cs.sorted(by: { $0.key < $1.key }) where abs(n) > 0.005 && c.count == 3 && c.uppercased() == c && !held.contains(where: { $0.c == c }) {
            add(c, L.base)
        }
    }
    // anything else that already has prices
    for p in L.prices where !seen.contains(p.currency.map { $0 + "/" + (p.quote ?? "") } ?? "") {
        if let c = p.currency, let q = p.quote, out.count < 40 { add(c, q) }
    }
    return out
}

/// 更新价格's lines for the prices typed in (a positive amount each), in `priceItems` order
public func typedPriceLines(_ items: [PriceItem], _ values: [String: String], date: String) -> [String] {
    items.compactMap { it in
        guard let v = evalAmount(values[it.id] ?? ""), v > 0 else { return nil }
        return "\(date) price \(it.c)" + String(repeating: " ", count: max(1, 26 - it.c.count)) + jsNumberString(roundTo(v, 6)) + " " + it.q
    }
}

/// 投资收入: Income:Invest:* (or any income account under an "Invest" group) in the base currency, as
/// (account, this year, all time), the largest first
public func investIncome(_ L: Ledger, year: String) -> [(account: String, year: Double, all: Double)] {
    var ytd: [String: Double] = [:], all: [String: Double] = [:]
    for t in L.txns {
        for p in t.postings where p.units != nil && p.account.hasPrefix("Income:") && p.account.components(separatedBy: ":").contains(where: { $0.hasPrefix("Invest") }) {
            let v = -(toCNY(L, p.units!, p.currency ?? L.base, t.date) ?? 0)
            all[p.account, default: 0] += v
            if t.date.hasPrefix(year) { ytd[p.account, default: 0] += v }
        }
    }
    return all.keys.sorted { abs(all[$0]!) > abs(all[$1]!) }.map { ($0, ytd[$0] ?? 0, all[$0]!) }
}
