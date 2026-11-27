import Foundation
import LedgerKit

extension PriceFetch {
    static let autoKey = "ledger.prices.auto"
    static let lastKey = "ledger.prices.lastAuto"

    /// last automatic attempt per ledger (this run only)
    static var lastTry: [String: Date] = [:]
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
        let items = priceItems(L).filter { $0.date != today }
        guard !items.isEmpty else { UserDefaults.standard.set(today, forKey: key); return }
        let got = await PriceFetch.fetchAll(items, L)
        guard !got.isEmpty else { return }
        UserDefaults.standard.set(today, forKey: key)
        let lines = items.compactMap { it in got[it.id].map { PriceFetch.line(today, it.c, it.q, $0) } }
        guard !lines.isEmpty, let ops = makeOps(lines.joined(separator: "\n"), extra: OpExtra(label: LS("自动更新价格：%@ 项", lines.count)), single: false) else { return }
        await commit(ops, word: LS("已自动更新 %@ 项价格", lines.count))
    }
}
