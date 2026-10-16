import Foundation

// MARK: - a new, empty ledger with another one's structure (演示账本 → 我的账本)
//
// The accounts and categories, the currencies and the layout come across; no transactions, balances, prices,
// budgets or subscriptions, and nothing that describes the other ledger's own cards (statement days, limits) or
// its owner (payslips, scanned cards, saved searches, the default paying account).

public enum EmptyLedger {
    /// the day the accounts are opened on: early, so entries for any past day can be added
    public static let openDate = "1970-01-01"

    /// the files of the new ledger, by path
    public static func files(from L: Ledger, title: String, year: String) -> [String: String] {
        var main: [String] = [";" + " " + tr("由 Ledger X 新建的账本：账户与分类来自演示账本，没有交易", "A ledger made by Ledger X: accounts and categories from the demo, no transactions")]
        main.append("option \"title\" \(quoted(title))")
        for c in L.options["operating_currency"] ?? [] { if let c = c { main.append("option \"operating_currency\" \"\(c)\"") } }
        if let b = L.options["booking_method"]?.first, let bb = b { main.append("option \"booking_method\" \"\(bb)\"") }
        main.append("")
        for f in ["config/commodities.bean", "accounts/accounts.bean", "accounts/balance.bean", "journals/\(year).bean", "prices.bean"] {
            main.append("include \"\(f)\"")
        }

        // the currencies and securities, as declared
        var commodities: [String] = []
        for e in L.entries where e.type == .commodity {
            guard let c = e.currency else { continue }
            commodities.append("\(openDate) commodity \(c)")
            if let n = e.meta["name"]?.stringValue { commodities.append("  name: \(quoted(n))") }
            if let p = e.meta["price"]?.stringValue { commodities.append("  price: \(quoted(p))") }
        }

        // every account still open, by root, with its currencies, booking and display name
        var accounts: [String] = []
        let roots = [("Assets", tr("资产", "Assets")), ("Liabilities", tr("负债", "Liabilities")), ("Equity", tr("权益", "Equity")),
                     ("Income", tr("收入", "Income")), ("Expenses", tr("支出", "Expenses"))]
        for (root, label) in roots {
            let names = L.accounts.filter { $0.key.hasPrefix(root + ":") && $0.value.close == nil && !$0.value.implicit }.keys.sorted()
            if names.isEmpty { continue }
            if !accounts.isEmpty { accounts.append("") }
            accounts.append("; " + label)
            for a in names {
                let acc = L.accounts[a]!
                var line = "\(openDate) open \(a)"
                if !acc.currencies.isEmpty { line += String(repeating: " ", count: max(1, 48 - a.count)) + acc.currencies.joined(separator: ",") }
                if let b = acc.booking { line += " \"\(b)\"" }
                accounts.append(line)
                if let n = acc.meta["name"]?.stringValue { accounts.append("  name: \(quoted(n))") }
            }
        }

        let year0 = "; " + tr("交易按年份写在 journals/ 里", "Transactions go in journals/, a file a year")
        return [
            "main.bean": main.joined(separator: "\n") + "\n",
            "config/commodities.bean": (["; " + tr("币种与证券", "Currencies and securities")] + commodities).joined(separator: "\n") + "\n",
            "accounts/accounts.bean": accounts.joined(separator: "\n") + "\n",
            "accounts/balance.bean": "; " + tr("余额断言", "Balance assertions") + "\n",
            "journals/\(year).bean": year0 + "\n",
            "prices.bean": "; " + tr("价格", "Prices") + "\n",
            "ledger-x.json": config(L),
        ]
    }

    /// ledger-x.json: where each kind of entry goes, and the default currency
    static func config(_ L: Ledger) -> String {
        let files: [String: String] = [
            "accounts": "accounts/accounts.bean",
            "balance": "accounts/balance.bean",
            "commodity": "config/commodities.bean",
            "price": "prices.bean",
            "transactions": "journals/{year}.bean",
        ]
        let obj: [String: Any] = ["main": "main.bean", "default_currency": L.base, "files": files]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
