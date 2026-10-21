import Foundation

// MARK: - 往来: money owed between you and people, the company and the reimbursement desk
//
// People share one receivable account; each posting on it says who it is with:
//   Assets:Receivable:Personal        paid for them, lent to them, split with them (positive: they owe you;
//     person: "五姨"                  negative: they paid for you)
//   Liabilities:Loan:<Key>            money you borrowed from them; the account's `name:` is the person
// What they owe you is the sum of the two. Sub-accounts of Assets:Receivable:Personal (the older layout) still
// work: without `person:` their `name:` (or last part) is the person.
// The company's account is Assets:Receivable:Employer (salary paid short: positive; paid over: negative),
// each month's difference linked ^salary-….

public let personalAccount = "Assets:Receivable:Personal"
public let loanPrefix = "Liabilities:Loan:"
/// posting metadata naming the person a personal receivable is with
public let personMeta = "person"

public func isPersonal(_ a: String) -> Bool { a == personalAccount || a.hasPrefix(personalAccount + ":") }

/// the loan account's own part: "WuYi" for Liabilities:Loan:WuYi or Liabilities:Loan:WuYi:Car
public func loanKey(_ a: String) -> String? {
    guard a.hasPrefix(loanPrefix) else { return nil }
    let k = String(a.dropFirst(loanPrefix.count)).components(separatedBy: ":")[0]
    return k.isEmpty ? nil : k
}

/// who a loan account is with: the `name:` on Liabilities:Loan:<Key>, else the key
public func loanPerson(_ L: Ledger, _ a: String) -> String? {
    guard let k = loanKey(a) else { return nil }
    return metaName(L, loanPrefix + k) ?? k
}

/// the `person:` written on a posting, trimmed (nil when absent or empty)
public func postingPerson(_ p: Posting) -> String? {
    guard let v = p.meta[personMeta] else { return nil }
    let s = (v.stringValue ?? v.display).trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? nil : s
}

/// who a posting is with: a personal receivable's `person:` ("" when it names nobody), a loan account's person;
/// nil for every other account
public func personOf(_ p: Posting, _ L: Ledger) -> String? {
    if isPersonal(p.account) {
        if let n = postingPerson(p) { return n }
        return p.account == personalAccount ? "" : metaName(L, p.account) ?? leaf(p.account)
    }
    return loanPerson(L, p.account)
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
    /// the name: `person:` on the receivable postings, the loan account's `name:`; "" for receivables that name nobody
    public let name: String
    /// their Liabilities:Loan accounts
    public let loans: [String]
    /// per account (the personal receivable, their loan accounts) and currency: their part of its balance
    public let balances: [String: [String: Double]]
    /// what they owe you per currency; negative when you owe them
    public let net: [String: Double]
    /// the same in CNY
    public let netCNY: Double
    /// their latest transaction
    public let last: String?
    /// only loan accounts, all closed: nothing more will happen with them
    public let closed: Bool
    public var id: String { name }
    public var key: String { name }
    /// receivable postings that say nobody (no `person:`)
    public var unnamed: Bool { name.isEmpty }
    public var settled: Bool { net.values.allSatisfy { abs($0) < 0.005 } }
    /// the open loan account to borrow and repay on, if they have one
    public func loan(_ L: Ledger) -> String? { loans.first { L.accounts[$0]?.close == nil } ?? loans.first }
}

/// everyone with a personal receivable posting or a loan account: who still owes (or is owed) first, the largest
/// first; then the settled ones, most recent first
public func people(_ L: Ledger) -> [Person] {
    var bal: [String: [String: [String: Double]]] = [:]
    var loans: [String: [String]] = [:]
    var last: [String: String] = [:]
    var receivable = Set<String>()
    for a in L.accounts.keys.sorted() {
        guard let who = loanPerson(L, a) else { continue }
        loans[who, default: []].append(a)
    }
    for t in L.txns {
        for p in t.postings {
            guard let who = personOf(p, L) else { continue }
            if isPersonal(p.account) { receivable.insert(who) }
            if (last[who] ?? "") < t.date { last[who] = t.date }
            guard let u = p.units, let c = p.currency else { continue }
            bal[who, default: [:]][p.account, default: [:]][c, default: 0] += u
        }
    }
    var out: [Person] = []
    for who in Set(loans.keys).union(bal.keys) {
        var b: [String: [String: Double]] = [:], net: [String: Double] = [:]
        for (a, m) in bal[who] ?? [:] {
            for (c, v) in m where abs(v) > 1e-9 {
                b[a, default: [:]][c] = roundTo(v, 2)
                net[c, default: 0] += v
            }
        }
        net = net.mapValues { roundTo($0, 2) }.filter { abs($0.value) > 0.005 }
        let cny = net.reduce(0.0) { $0 + (toCNY(L, $1.value, $1.key) ?? 0) }
        let ls = loans[who] ?? []
        let closed = !receivable.contains(who) && !ls.isEmpty && ls.allSatisfy { L.accounts[$0]?.close != nil }
        out.append(Person(name: who, loans: ls, balances: b, net: net, netCNY: roundTo(cny, 2), last: last[who], closed: closed))
    }
    return out.sorted { a, b in
        if a.settled != b.settled { return !a.settled }
        if !a.settled { return abs(a.netCNY) != abs(b.netCNY) ? abs(a.netCNY) > abs(b.netCNY) : a.name < b.name }
        return (a.last ?? "") != (b.last ?? "") ? (a.last ?? "") > (b.last ?? "") : a.name < b.name
    }
}

/// the person's transactions, newest first
public func personEntries(_ L: Ledger, _ name: String) -> [Entry] {
    L.txns.filter { t in t.postings.contains { personOf($0, L) == name } }.reversed()
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
/// Only ^salary-… links count (a payslip netted against a reimbursement carries both links). One entry can
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
        let links = t.links.filter(isSalaryLink)
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

/// how an open difference with the company is closed when the money really moves: the company as payee, the
/// account the salary went to, and a description ("2026-08 工资补发" / "2026-08 退回多发工资")
public struct EmployerSettlement: Equatable {
    public let payee: String
    /// where the salary of that month was paid (nil when no salary entry is linked)
    public let account: String?
    public let narration: String
}

public func employerSettlement(_ L: Ledger, _ x: OpenDifference) -> EmployerSettlement {
    // the salary entry of that month (else the latest one): who paid and into which account
    let salary: (Entry) -> Bool = { t in t.postings.contains { $0.account.hasPrefix("Income:Salary") } }
    let t = x.link.flatMap { l in L.txns.last { $0.links.contains(l) && salary($0) } }
        ?? L.txns.last { t in salary(t) && t.links.contains(where: isSalaryLink) }
    let account = t?.postings.first { p in
        (p.units ?? 0) > 0 && (p.account.hasPrefix("Assets:") || p.account.hasPrefix("Liabilities:"))
            && !isSalaryClearing(p.account) && !p.account.hasPrefix("Assets:Receivable")
    }?.account
    // the month from the link's last part (YYYYMM)
    var month = ""
    if let l = x.link, let last = l.split(separator: "-").last, last.count == 6, Int(last) != nil {
        month = last.prefix(4) + "-" + last.suffix(2)
    }
    let what = x.amount > 0 ? tr("工资补发", "back pay") : tr("退回多发工资", "overpaid salary returned")
    return EmployerSettlement(payee: t?.payee.isEmpty == false ? t!.payee : "", account: account,
                              narration: month.isEmpty ? what : month + " " + what)
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
    /// on the personal receivable (lend, collect) rather than a loan account (borrow, repay)
    public var receivable: Bool { self == .lend || self == .collect }
}

public struct LoanDraft: Equatable {
    public var kind: LoanKind = .lend
    public var date = Day.today()
    /// who: written as `person:` (lend, collect) or the new loan account's `name:` (borrow, repay)
    public var name = ""
    /// Liabilities:Loan:<key> for someone you have not borrowed from before
    public var key = ""
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

/// the open directive for the personal receivable when the ledger has none yet
func personalOpenLine(_ L: Ledger, date: String) -> String? {
    L.accounts[personalAccount] == nil || L.accounts[personalAccount]!.implicit ? openLine(personalAccount, date: date, name: tr("个人往来", "People")) : nil
}

/// a posting on the personal receivable for one person
public func personalPosting(_ person: String, amount: Double, currency: String) -> TxPosting {
    var p = TxPosting(account: personalAccount, amount: amount, currency: currency)
    p.meta = [(personMeta, person)]
    return p
}

/// the loan account a borrow or repay goes to: theirs when they have one, else Liabilities:Loan:<key>
public func loanAccount(_ d: LoanDraft, _ L: Ledger) -> String? {
    let name = d.name.trimmingCharacters(in: .whitespaces)
    if let p = people(L).first(where: { $0.name == name }), let a = p.loan(L) { return a }
    let key = d.key.trimmingCharacters(in: .whitespaces)
    return validAccountPart(key) ? loanPrefix + key : nil
}

/// the Beancount text for a loan entry (with the account opened first when the ledger lacks it)
public func loanText(_ d: LoanDraft, _ L: Ledger) -> String {
    let name = d.name.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, let amt = evalAmount(d.amount), amt > 0, !d.account.isEmpty, !d.date.isEmpty else { return "" }
    var parts: [String] = []
    let sign: Double = d.kind == .lend || d.kind == .repay ? 1 : -1
    let theirs: TxPosting
    if d.kind.receivable {
        if let o = personalOpenLine(L, date: d.date) { parts.append(o) }
        theirs = personalPosting(name, amount: sign * amt, currency: d.currency)
    } else {
        guard let a = loanAccount(d, L) else { return "" }
        if L.accounts[a] == nil || L.accounts[a]!.implicit { parts.append(openLine(a, date: d.date, name: name)) }
        theirs = TxPosting(account: a, amount: sign * amt, currency: d.currency)
    }
    var tx = TxDraft(date: d.date)
    tx.payee = name
    let note = d.note.trimmingCharacters(in: .whitespaces)
    tx.narration = note.isEmpty ? d.kind.label : note
    tx.postings = [theirs, TxPosting(account: d.account, amount: -sign * amt, currency: d.currency)]
    parts.append(formatTxn(tx))
    return parts.joined(separator: "\n\n")
}

/// one balance to bring to zero
public struct SettleItem: Equatable, Hashable {
    public let account: String
    public let currency: String
    /// the balance now
    public let amount: Double
    /// whose part of a shared account it is (`person:` on the posting)
    public let person: String?
    public init(account: String, currency: String, amount: Double, person: String? = nil) {
        self.account = account; self.currency = currency; self.amount = amount; self.person = person
    }
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
        var p = TxPosting(account: i.account, amount: -roundMoney(i.amount, 2), currency: i.currency)
        if let who = i.person, !who.isEmpty { p.meta = [(personMeta, who)] }
        tx.postings.append(p)
        if back[i.currency] == nil { order.append(i.currency) }
        back[i.currency, default: 0] += i.amount
    }
    for c in order { tx.postings.append(TxPosting(account: to, amount: roundMoney(back[c]!, 2), currency: c)) }
    parts.append(formatTxn(tx))
    return parts.joined(separator: "\n\n")
}

/// split `total` evenly between you and `n` others, to the cent; each of theirs (you take the odd cents)
public func evenShares(_ total: Double, _ n: Int) -> [Double] {
    guard n > 0, total > 0 else { return [] }
    let each = (total / Double(n + 1) * 100).rounded(.down) / 100
    return Array(repeating: each, count: n)
}
