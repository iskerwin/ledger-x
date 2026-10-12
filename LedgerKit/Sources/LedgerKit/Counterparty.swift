import Foundation

// MARK: - 往来: money owed between you and people, the company and the reimbursement desk
//
// One person, two accounts at most, both keyed by the same name:
//   Assets:Receivable:Personal:<Key>  paid for them, lent to them, split with them (positive: they owe you;
//                                     negative: they paid for you)
//   Liabilities:Loan:<Key>            money you borrowed from them
// What they owe you is the sum of the two. The company's account is Assets:Receivable:Employer
// (salary paid short: positive; paid over: negative), each month's difference linked ^salary-….

public let personalPrefix = "Assets:Receivable:Personal:"
public let loanPrefix = "Liabilities:Loan:"

/// the person an account belongs to: "WuYi" for Assets:Receivable:Personal:WuYi or Liabilities:Loan:WuYi
public func personKey(_ a: String) -> String? {
    for p in [personalPrefix, loanPrefix] where a.hasPrefix(p) {
        let k = String(a.dropFirst(p.count)).components(separatedBy: ":")[0]
        return k.isEmpty ? nil : k
    }
    return nil
}

/// an account name part Beancount accepts: a capital letter or digit, then letters, digits and dashes
public func validAccountPart(_ s: String) -> Bool {
    s.range(of: #"^[A-Z0-9][A-Za-z0-9\-]*$"#, options: .regularExpression) != nil
}

/// a likely account part for a name: "五姨" → "WuYi", "王五" → "WangWu", "wang wu" → "WangWu";
/// nil when nothing usable is left
public func accountPart(from s: String) -> String? {
    var parts: [String] = [], word = ""
    func flush() { if !word.isEmpty { parts.append(word); word = "" } }
    for ch in s.trimmingCharacters(in: .whitespaces) {
        guard let u = ch.unicodeScalars.first else { continue }
        if isHan(u) {
            flush()
            var py = String(ch).applyingTransform(.toLatin, reverse: false) ?? ""
            py = (py.applyingTransform(.stripDiacritics, reverse: false) ?? py).lowercased()
            py = String(py.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.map(Character.init))
            if !py.isEmpty { parts.append(py) }
        } else if u.isASCII && CharacterSet.alphanumerics.contains(u) {
            word.append(ch)
        } else {
            flush()
        }
    }
    flush()
    let joined = parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    return validAccountPart(joined) ? joined : nil
}

/// the `name:` given on the account's open directive, if any
public func metaName(_ L: Ledger, _ a: String) -> String? {
    guard let v = L.accounts[a]?.meta["name"] else { return nil }
    let s = v.stringValue ?? v.display
    return s.isEmpty ? nil : s
}

public struct Person: Identifiable, Equatable {
    public let key: String
    public let name: String
    /// Assets:Receivable:Personal:<key>, when it exists
    public let receivable: String?
    /// Liabilities:Loan:<key>, when it exists
    public let loan: String?
    /// every account of theirs (sub-accounts too) with its balances
    public let balances: [String: [String: Double]]
    /// what they owe you per currency; negative when you owe them
    public let net: [String: Double]
    /// the same in CNY
    public let netCNY: Double
    /// their latest transaction
    public let last: String?
    /// every account of theirs is closed
    public let closed: Bool
    public var id: String { key }
    public var settled: Bool { net.values.allSatisfy { abs($0) < 0.005 } }
}

/// everyone with a personal receivable or loan account: who still owes (or is owed) first, the largest
/// first; then the settled ones, most recent first
public func people(_ L: Ledger) -> [Person] {
    var accts: [String: [String]] = [:]
    for a in L.accounts.keys.sorted() {
        guard let k = personKey(a) else { continue }
        accts[k, default: []].append(a)
    }
    guard !accts.isEmpty else { return [] }
    var last: [String: String] = [:]
    for t in L.txns {
        for p in t.postings { if let k = personKey(p.account), (last[k] ?? "") < t.date { last[k] = t.date } }
    }
    var out: [Person] = []
    for (k, list) in accts {
        let rec = personalPrefix + k, loan = loanPrefix + k
        var bal: [String: [String: Double]] = [:], net: [String: Double] = [:]
        for a in list {
            for (c, v) in L.final[a] ?? [:] where abs(v) > 1e-9 {
                bal[a, default: [:]][c] = v
                net[c, default: 0] += v
            }
        }
        net = net.mapValues { roundTo($0, 2) }.filter { abs($0.value) > 0.005 }
        let cny = net.reduce(0.0) { $0 + (toCNY(L, $1.value, $1.key) ?? 0) }
        let name = metaName(L, rec) ?? metaName(L, loan) ?? k
        let closed = list.allSatisfy { L.accounts[$0]?.close != nil }
        out.append(Person(key: k, name: name, receivable: L.accounts[rec] != nil ? rec : nil, loan: L.accounts[loan] != nil ? loan : nil,
                          balances: bal, net: net, netCNY: roundTo(cny, 2), last: last[k], closed: closed))
    }
    return out.sorted { a, b in
        if a.settled != b.settled { return !a.settled }
        if !a.settled { return abs(a.netCNY) != abs(b.netCNY) ? abs(a.netCNY) > abs(b.netCNY) : a.key < b.key }
        return (a.last ?? "") != (b.last ?? "") ? (a.last ?? "") > (b.last ?? "") : a.key < b.key
    }
}

/// the person's transactions, newest first
public func personEntries(_ L: Ledger, _ key: String) -> [Entry] {
    L.txns.filter { t in t.postings.contains { personKey($0.account) == key } }.reversed()
}

/// an open difference on the company's account: one ^salary-… link, or (link nil) what no link explains
public struct OpenDifference: Identifiable, Equatable {
    public let link: String?
    public let account: String
    public let amount: Double
    public let currency: String
    public let n: Int
    public let date: String
    public var id: String { (link ?? "") + "|" + account + "|" + currency }
}

/// the company's account: its balance per currency, and what is still open behind it.
/// Only ^salary-… and ^float-… (备用金) links count (a payslip netted against a reimbursement carries both links). One entry can
/// settle several months at once: each of its postings goes to the month it cancels exactly, the rest to the
/// entry's first salary link.
public func employerOpen(_ L: Ledger) -> (total: [String: Double], open: [OpenDifference]) {
    var total: [String: Double] = [:]
    var sum: [String: Double] = [:], n: [String: Int] = [:], date: [String: String] = [:], order: [String] = []
    var acctOf: [String: String] = [:]
    func add(_ k: String, _ v: Double, _ t: Entry, _ a: String) {
        if sum[k] == nil { order.append(k) }
        sum[k, default: 0] += v
        n[k, default: 0] += 1
        date[k] = t.date
        acctOf[k] = a
    }
    for t in L.txns {
        let ps = t.postings.filter { isSalaryClearing($0.account) }
        if ps.isEmpty { continue }
        let links = t.links.filter(isEmployerLink)
        var used = Set<String>()
        for p in ps {
            let c = p.currency ?? L.base, v = p.units ?? 0
            total[c, default: 0] += v
            guard let first = links.first else { continue }
            var key = first + "\u{1}" + c
            if links.count > 1 {
                // the month this posting closes exactly, if there is one
                if let l = links.first(where: { !used.contains($0) && abs((sum[$0 + "\u{1}" + c] ?? 0) + v) < 0.005 && sum[$0 + "\u{1}" + c] != nil }) {
                    key = l + "\u{1}" + c
                    used.insert(l)
                }
            }
            add(key, v, t, p.account)
        }
    }
    var open: [OpenDifference] = []
    var linked: [String: Double] = [:]
    for k in order {
        let parts = k.components(separatedBy: "\u{1}")
        let v = roundTo(sum[k] ?? 0, 2)
        linked[parts[1], default: 0] += v
        if abs(v) > 0.005 {
            open.append(OpenDifference(link: parts[0], account: acctOf[k] ?? "", amount: v, currency: parts[1], n: n[k] ?? 0, date: date[k] ?? ""))
        }
    }
    total = total.mapValues { roundTo($0, 2) }.filter { abs($0.value) > 0.005 }
    for c in Set(total.keys).union(linked.keys).sorted() {
        let rest = roundTo((total[c] ?? 0) - (linked[c] ?? 0), 2)
        if abs(rest) > 0.005 {
            let acct = L.accounts.keys.filter(isSalaryClearing).sorted().first ?? "Assets:Receivable:Employer"
            open.append(OpenDifference(link: nil, account: acct, amount: rest, currency: c, n: 0, date: ""))
        }
    }
    return (total, open)
}

// MARK: - entries

public enum LoanKind: String, CaseIterable, Identifiable {
    /// you lend them money / they pay it back / you borrow from them / you pay it back
    case lend, collect, borrow, repay
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .lend: return tr("借出", "Lend")
        case .collect: return tr("收回", "Collect")
        case .borrow: return tr("借入", "Borrow")
        case .repay: return tr("还钱", "Repay")
        }
    }
    /// money comes into your account
    public var incoming: Bool { self == .collect || self == .borrow }
    /// the person's account this goes to
    public func account(_ key: String) -> String { (self == .lend || self == .collect ? personalPrefix : loanPrefix) + key }
}

public struct LoanDraft: Equatable {
    public var kind: LoanKind = .lend
    public var date = Day.today()
    public var key = ""
    public var name = ""
    public var amount = ""
    public var currency = "CNY"
    /// your account the money leaves or comes into
    public var account = ""
    public var note = ""
    public init() {}
}

/// `open` directive for an account the entry needs and the ledger doesn't have yet
func openLine(_ account: String, date: String, name: String?) -> String {
    var s = "\(date) open \(account)"
    if let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty, n != leaf(account) {
        s += "\n  name: \"\(n.replacingOccurrences(of: "\"", with: "'"))\""
    }
    return s
}

/// the Beancount text for a loan entry (with the person's account opened first when it is new)
public func loanText(_ d: LoanDraft, _ L: Ledger) -> String {
    let key = d.key.trimmingCharacters(in: .whitespaces)
    guard validAccountPart(key), let amt = evalAmount(d.amount), amt > 0, !d.account.isEmpty, !d.date.isEmpty else { return "" }
    let target = d.kind.account(key)
    let name = d.name.trimmingCharacters(in: .whitespaces)
    var parts: [String] = []
    if L.accounts[target] == nil || L.accounts[target]!.implicit {
        // the name on the other account of theirs, when this one is new
        parts.append(openLine(target, date: d.date, name: name.isEmpty ? metaName(L, LoanKind.lend.account(key)) ?? metaName(L, LoanKind.borrow.account(key)) : name))
    }
    var tx = TxDraft(date: d.date)
    tx.payee = name.isEmpty ? key : name
    let note = d.note.trimmingCharacters(in: .whitespaces)
    tx.narration = note.isEmpty ? d.kind.label : note
    let sign: Double = d.kind == .lend || d.kind == .repay ? 1 : -1
    tx.postings = [TxPosting(account: target, amount: sign * amt, currency: d.currency),
                   TxPosting(account: d.account, amount: -sign * amt, currency: d.currency)]
    parts.append(formatTxn(tx))
    return parts.joined(separator: "\n\n")
}

/// one balance to bring to zero
public struct SettleItem: Equatable, Hashable {
    public let account: String
    public let currency: String
    /// the balance now
    public let amount: Double
    public init(account: String, currency: String, amount: Double) { self.account = account; self.currency = currency; self.amount = amount }
}

/// Close out what is left: each item's balance goes to `to` (报销差额, 工资, 礼金…), linked when a link is given.
/// `to` is opened first when the ledger doesn't have it yet.
public func settleText(_ L: Ledger, date: String, payee: String, narration: String, link: String?, items: [SettleItem], to: String) -> String {
    let items = items.filter { abs($0.amount) > 0.005 }
    guard !items.isEmpty, !to.isEmpty, !date.isEmpty else { return "" }
    var parts: [String] = []
    if L.accounts[to] == nil || L.accounts[to]!.implicit { parts.append(openLine(to, date: date, name: nil)) }
    var tx = TxDraft(date: date)
    tx.payee = payee
    tx.narration = narration
    if let l = link, !l.isEmpty { tx.links = [l] }
    var back: [String: Double] = [:], order: [String] = []
    for i in items {
        tx.postings.append(TxPosting(account: i.account, amount: -roundTo(i.amount, 2), currency: i.currency))
        if back[i.currency] == nil { order.append(i.currency) }
        back[i.currency, default: 0] += i.amount
    }
    for c in order { tx.postings.append(TxPosting(account: to, amount: roundTo(back[c]!, 2), currency: c)) }
    parts.append(formatTxn(tx))
    return parts.joined(separator: "\n\n")
}

/// split `total` evenly between you and `n` others, to the cent; each of theirs (you take the odd cents)
public func evenShares(_ total: Double, _ n: Int) -> [Double] {
    guard n > 0, total > 0 else { return [] }
    let each = (total / Double(n + 1) * 100).rounded(.down) / 100
    return Array(repeating: each, count: n)
}
