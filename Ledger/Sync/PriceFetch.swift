import Foundation
import LedgerKit

/// Prices from Yahoo Finance. A commodity can say where its price comes from with bean-price's
/// metadata, e.g.  2025-01-01 commodity VOO  /  price: "USD:yahoo/VOO"  (or "CNY:yahoo/510300.SS").
/// Without it: currencies use "USDCNY=X", anything else its own name as the ticker.
enum PriceFetch {
    static let autoKey = "ledger.prices.auto"
    static let lastKey = "ledger.prices.lastAuto"

    /// the Yahoo symbol for commodity `c` quoted in `q`, and whether the quote is inverted
    static func symbol(_ c: String, _ q: String, _ L: Ledger) -> (String, Bool) {
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

    struct Quote { let price: Double; let currency: String? }

    static func fetch(_ symbol: String) async throws -> Quote {
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

    /// prices for the rows of the price sheet; failures are left out
    static func fetchAll(_ items: [PriceItem], _ L: Ledger) async -> [String: Double] {
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

    /// last automatic attempt per ledger (this run only)
    static var lastTry: [String: Date] = [:]

    static func line(_ date: String, _ c: String, _ q: String, _ v: Double) -> String {
        "\(date) price \(c)" + String(repeating: " ", count: max(1, 26 - c.count)) + jsNumberString(roundTo(v, v < 10 ? 6 : 4)) + " " + q
    }
}

extension Store {
    /// once a day, when switched on: fetch and write prices for everything held
    func autoUpdatePrices() async {
        guard !demo, UserDefaults.standard.bool(forKey: PriceFetch.autoKey), let L = L else { return }
        let today = Day.today()
        // per ledger, and only marked done once prices were actually fetched; a failed try
        // (offline at launch) is retried after a while instead of waiting for tomorrow
        let key = PriceFetch.lastKey + "@" + cfg.id
        guard UserDefaults.standard.string(forKey: key) != today else { return }
        if let t = PriceFetch.lastTry[cfg.id], Date().timeIntervalSince(t) < 1800 { return }
        PriceFetch.lastTry[cfg.id] = Date()
        let items = PriceUpdateSheet.items(L).filter { $0.date != today }
        guard !items.isEmpty else { UserDefaults.standard.set(today, forKey: key); return }
        let got = await PriceFetch.fetchAll(items, L)
        guard !got.isEmpty else { return }
        UserDefaults.standard.set(today, forKey: key)
        let lines = items.compactMap { it in got[it.id].map { PriceFetch.line(today, it.c, it.q, $0) } }
        guard !lines.isEmpty, let ops = makeOps(lines.joined(separator: "\n"), extra: OpExtra(label: LS("自动更新价格：%@ 项", lines.count)), single: false) else { return }
        await commit(ops, word: LS("已自动更新 %@ 项价格", lines.count))
    }
}
