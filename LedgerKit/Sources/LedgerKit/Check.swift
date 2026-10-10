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

/// A balance assertion dated after today that a change moves. Such an assertion holds the balance
/// as it is now (dated the first of next month, say), so every new entry is expected to change it:
/// it is updated together with the entry instead of blocking it.
public struct RunningBalance: Identifiable, Equatable {
    public let account: String
    public let currency: String
    public let date: String
    public let file: String
    /// the first line of the assertion as written
    public let line: String
    /// the amount asserted now
    public let asserted: Double
    /// the balance once the change is made
    public let computed: Double
    public var id: String { date + "|" + account + "|" + currency }
}

private func balanceKey(_ r: BalanceResult) -> String { "\(r.entry.date)|\(r.entry.account ?? "")|\(r.entry.currency ?? "")" }

/// future-dated assertions that held before the change and fail after it
public func runningBalances(before: Ledger, after: Ledger, today: String) -> [RunningBalance] {
    let failedBefore = Set(before.balanceResults.filter { !$0.ok }.map(balanceKey))
    return after.balanceResults.filter { !$0.ok && $0.entry.date > today && !failedBefore.contains(balanceKey($0)) }.map { r in
        let e = r.entry
        return RunningBalance(account: e.account ?? "", currency: e.currency ?? "", date: e.date, file: e.file,
                              line: e.src.components(separatedBy: "\n").first ?? "", asserted: e.number, computed: r.got)
    }
}

/// the op that rewrites a running assertion with a new amount (a trailing comment is kept)
public func runningBalanceOp(_ r: RunningBalance, amount: Double) -> Op {
    var op = Op(kind: .balance, path: r.file)
    op.account = r.account; op.date = r.date; op.currency = r.currency
    op.replace = true
    var line = balanceLine(r.date, r.account, amount, r.currency)
    if let c = r.line.range(of: " ;") { line += " " + r.line[c.lowerBound...].trimmingCharacters(in: .whitespaces) }
    op.line = line
    op.amountText = plainMoney(amount, r.currency)
    op.label = tr("更新余额断言：\(r.account) \(r.date)", "Update balance: \(r.account) \(r.date)")
    op.summary = tr("余额断言 \(r.account)", "balance \(r.account)")
    op.silent = true
    return op
}

/// compare the ledger before and after a change; only problems the change introduces are reported,
/// so a ledger that already had a failing assertion does not block every later edit.
/// With `today`, assertions dated after it are left out: they are running balances (`runningBalances`).
public func reviewChange(before: Ledger, after: Ledger, today: String? = nil) -> [ChangeIssue] {
    var out: [ChangeIssue] = []

    // 1. balance assertions that newly fail
    let key = balanceKey
    let failedBefore = Set(before.balanceResults.filter { !$0.ok }.map(key))
    for r in after.balanceResults where !r.ok && !failedBefore.contains(key(r)) && !(today.map { r.entry.date > $0 } ?? false) {
        let e = r.entry
        out.append(ChangeIssue(kind: .balance,
                               title: tr("余额断言将失败：\(acctLabel(e.account ?? ""))", "Balance assertion would fail: \(e.account ?? "")"),
                               detail: tr("\(e.date) 应为 \(fmtNum(e.number)) \(e.currency ?? "")，修改后为 \(fmtNum(r.got))（差 \(fmtNum(r.diff))）",
                                          "\(e.date): expected \(fmtNum(e.number)) \(e.currency ?? ""), would be \(fmtNum(r.got)) (off by \(fmtNum(r.diff)))"),
                               account: e.account))
    }

    // 2. other new errors (unbalanced, account not open / closed, currency not allowed, lots…);
    // numbers are ignored when matching, so an old error whose amounts shifted is not "new"
    func norm(_ m: String) -> String { m.replacingOccurrences(of: "-?[0-9][0-9,]*(\\.[0-9]+)?", with: "#", options: .regularExpression) }
    var seen: [String: Int] = [:]
    for e in before.errors where e.entry?.type != .balance { seen[norm(e.msg), default: 0] += 1 }
    for e in after.errors where e.entry?.type != .balance {
        let k = norm(e.msg)
        if let n = seen[k], n > 0 { seen[k] = n - 1; continue }
        let at = e.entry.map { $0.date + " " + [$0.payee, $0.narration].filter { !$0.isEmpty }.joined(separator: " ") } ?? (e.file ?? "")
        out.append(ChangeIssue(kind: .error, title: e.msg, detail: at.trimmingCharacters(in: .whitespaces)))
    }

    // 3. Assets accounts going below zero, Liabilities beyond their credit limit — only on days the
    //    change made worse, so an account that was overdrawn once years ago is still checked today
    let serB = dailyBalances(before), serA = dailyBalances(after)
    for (k, days) in serA.sorted(by: { $0.key < $1.key }) {
        let parts = k.components(separatedBy: "|")
        let acct = parts[0], ccy = parts.count > 1 ? parts[1] : ""
        let account = after.accounts[acct]
        if acct.hasPrefix("Assets:") {
            if metaTrue(account?.meta[allowNegativeKey]) { continue }
            guard let hit = newLow(days, serB[k] ?? [], floor: 0) else { continue }
            out.append(ChangeIssue(kind: .insufficient,
                                   title: tr("余额不足：\(acctLabel(acct))", "Insufficient balance: \(acct)"),
                                   detail: tr("\(hit.date) 余额将变为 \(fmtNum(hit.value)) \(ccy)", "Balance would drop to \(fmtNum(hit.value)) \(ccy) on \(hit.date)"),
                                   account: acct))
        } else if acct.hasPrefix("Liabilities:"), let limit = creditLimit(account?.meta[creditLimitKey], ccy) {
            guard let hit = newLow(days, serB[k] ?? [], floor: -limit) else { continue }
            out.append(ChangeIssue(kind: .creditLimit,
                                   title: tr("超出信用额度：\(acctLabel(acct))", "Over the credit limit: \(acct)"),
                                   detail: tr("\(hit.date) 欠款将达 \(fmtNum(-hit.value)) \(ccy)，额度 \(fmtNum(limit))", "Owed \(fmtNum(-hit.value)) \(ccy) on \(hit.date), limit \(fmtNum(limit))"),
                                   account: acct))
        }
    }
    // the same problem found twice (two identical imported rows) is shown once
    var ids = Set<String>()
    out = out.filter { ids.insert($0.id).inserted }
    return out
}

/// end-of-day balance of every Assets / Liabilities account and currency, on the days it changed
func dailyBalances(_ L: Ledger) -> [String: [(date: String, value: Double)]] {
    var run: [String: Double] = [:]
    var out: [String: [(date: String, value: Double)]] = [:]
    var day = ""
    var touched = Set<String>()
    func close() {
        for k in touched { out[k, default: []].append((day, run[k] ?? 0)) }
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
    return out
}

/// the first day the balance is below `floor` and lower than it was on that day before the change
func newLow(_ after: [(date: String, value: Double)], _ before: [(date: String, value: Double)], floor: Double) -> (date: String, value: Double)? {
    var j = 0
    var prev = 0.0      // before-balance carried forward to the current day
    for a in after {
        while j < before.count && before[j].date <= a.date { prev = before[j].value; j += 1 }
        if a.value < floor - 0.005 && a.value < prev - 0.005 { return a }
    }
    return nil
}

func metaTrue(_ v: MetaValue?) -> Bool {
    guard let v = v else { return false }
    let s = (v.stringValue ?? v.display).lowercased()
    return s == "true" || s == "yes" || s == "1"
}

/// `credit_limit: 50000` or `credit_limit: "50000 CNY"`; a limit in another currency is ignored
public func creditLimit(_ v: MetaValue?, _ ccy: String) -> Double? {
    guard let v = v else { return nil }
    let parts = (v.stringValue ?? v.display).replacingOccurrences(of: ",", with: "").split(separator: " ").map(String.init)
    guard let first = parts.first, let n = Double(first), n > 0 else { return nil }
    if parts.count > 1, parts[1] != ccy { return nil }
    return n
}
