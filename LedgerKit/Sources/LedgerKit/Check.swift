import Foundation

/// something a pending change would break, found before it is written
public struct ChangeIssue: Identifiable, Equatable {
    public enum Kind: String { case balance, error, insufficient, creditLimit }
    public let kind: Kind
    public let title: String
    public let detail: String
    public var account: String?
    public var id: String { kind.rawValue + "|" + title + "|" + detail }
}

/// open-directive metadata that lets an Assets account go below zero
public let allowNegativeKey = "allow_negative"
/// open-directive metadata giving a credit card's limit, e.g. `credit_limit: 50000` or `"50000 CNY"`
public let creditLimitKey = "credit_limit"

/// compare the ledger before and after a change; only problems the change introduces are reported,
/// so a ledger that already had a failing assertion does not block every later edit
public func reviewChange(before: Ledger, after: Ledger) -> [ChangeIssue] {
    var out: [ChangeIssue] = []

    // 1. balance assertions that newly fail
    func key(_ r: BalanceResult) -> String { "\(r.entry.date)|\(r.entry.account ?? "")|\(r.entry.currency ?? "")" }
    let failedBefore = Set(before.balanceResults.filter { !$0.ok }.map(key))
    for r in after.balanceResults where !r.ok && !failedBefore.contains(key(r)) {
        let e = r.entry
        out.append(ChangeIssue(kind: .balance,
                               title: tr("余额断言将失败：\(acctLabel(e.account ?? ""))", "Balance assertion would fail: \(e.account ?? "")"),
                               detail: tr("\(e.date) 应为 \(fmtNum(e.number)) \(e.currency ?? "")，修改后为 \(fmtNum(r.got))（差 \(fmtNum(r.diff))）",
                                          "\(e.date): expected \(fmtNum(e.number)) \(e.currency ?? ""), would be \(fmtNum(r.got)) (off by \(fmtNum(r.diff)))"),
                               account: e.account))
    }

    // 2. other new errors (unbalanced, account not open / closed, currency not allowed, lots…)
    var seen: [String: Int] = [:]
    for e in before.errors where e.entry?.type != .balance { seen[e.msg, default: 0] += 1 }
    for e in after.errors where e.entry?.type != .balance {
        if let n = seen[e.msg], n > 0 { seen[e.msg] = n - 1; continue }
        let at = e.entry.map { $0.date + " " + [$0.payee, $0.narration].filter { !$0.isEmpty }.joined(separator: " ") } ?? (e.file ?? "")
        out.append(ChangeIssue(kind: .error, title: e.msg, detail: at.trimmingCharacters(in: .whitespaces)))
    }

    // 3. Assets accounts going below zero, Liabilities beyond their credit limit
    let lowB = lowPoints(before), lowA = lowPoints(after)
    for (k, a) in lowA.sorted(by: { $0.key < $1.key }) {
        let parts = k.components(separatedBy: "|")
        let acct = parts[0], ccy = parts.count > 1 ? parts[1] : ""
        let account = after.accounts[acct]
        if acct.hasPrefix("Assets:") {
            if metaTrue(account?.meta[allowNegativeKey]) { continue }
            guard a.min < -0.005 else { continue }
            if let b = lowB[k], a.min >= b.min - 0.005 { continue }      // not made worse by this change
            out.append(ChangeIssue(kind: .insufficient,
                                   title: tr("余额不足：\(acctLabel(acct))", "Insufficient balance: \(acct)"),
                                   detail: tr("\(a.date) 余额将变为 \(fmtNum(a.min)) \(ccy)", "Balance would drop to \(fmtNum(a.min)) \(ccy) on \(a.date)"),
                                   account: acct))
        } else if acct.hasPrefix("Liabilities:"), let limit = creditLimit(account?.meta[creditLimitKey], ccy) {
            guard a.min < -limit - 0.005 else { continue }
            if let b = lowB[k], a.min >= b.min - 0.005 { continue }
            out.append(ChangeIssue(kind: .creditLimit,
                                   title: tr("超出信用额度：\(acctLabel(acct))", "Over the credit limit: \(acct)"),
                                   detail: tr("\(a.date) 欠款将达 \(fmtNum(-a.min)) \(ccy)，额度 \(fmtNum(limit))", "Owed \(fmtNum(-a.min)) \(ccy) on \(a.date), limit \(fmtNum(limit))"),
                                   account: acct))
        }
    }
    return out
}

/// lowest end-of-day balance of every Assets / Liabilities account and currency
func lowPoints(_ L: Ledger) -> [String: (min: Double, date: String)] {
    var run: [String: Double] = [:]
    var low: [String: (min: Double, date: String)] = [:]
    var day = ""
    var touched = Set<String>()
    func close() {
        for k in touched {
            let v = run[k] ?? 0
            if let l = low[k] { if v < l.min - 1e-9 { low[k] = (v, day) } } else { low[k] = (v, day) }
        }
        touched.removeAll()
    }
    for t in L.txns {
        if t.date != day { close(); day = t.date }
        for p in t.postings where p.account.hasPrefix("Assets:") || p.account.hasPrefix("Liabilities:") {
            guard let u = p.units, let c = p.currency, p.cost == nil else { continue }
            let k = p.account + "|" + c
            run[k, default: 0] += u
            touched.insert(k)
        }
    }
    close()
    return low
}

func metaTrue(_ v: MetaValue?) -> Bool {
    guard let v = v else { return false }
    let s = (v.stringValue ?? v.display).lowercased()
    return s == "true" || s == "yes" || s == "1"
}

/// `credit_limit: 50000` or `credit_limit: "50000 CNY"`; a limit in another currency is ignored
func creditLimit(_ v: MetaValue?, _ ccy: String) -> Double? {
    guard let v = v else { return nil }
    let parts = (v.stringValue ?? v.display).replacingOccurrences(of: ",", with: "").split(separator: " ").map(String.init)
    guard let first = parts.first, let n = Double(first), n > 0 else { return nil }
    if parts.count > 1, parts[1] != ccy { return nil }
    return n
}
