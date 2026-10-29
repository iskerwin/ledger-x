import Foundation

// Credit card billing cycles, from metadata on the card's open directive:
//
//   2023-12-01 open Liabilities:CreditCard:CMB CNY
//     statement_day: 5        ; 账单日 (1–31, clamped to the month's last day)
//     due_day: 23             ; 还款日; when it is not after the statement day it falls in the next month
//     credit_limit: 50000
//
// The cycle closing on a statement date includes that day. The statement amount is what was owed at the
// end of that day; repayments (any increase of the card balance) after it count towards it.
//
// The bank's own figures for a statement, when written down, take the place of the ledger's (an instalment plan
// owes the whole principal in the ledger, but only this month's part on the bill):
//
//   2026-09-26 custom "card-bill" Liabilities:CreditCard:SPDB 857.03 CNY 29.13 CNY   ; 本期应还, 最低还款
//
// Without them the minimum payment is estimated: min_payment_rate on the open (0.05 or "5%"), 10% by default.
// Paying at least the minimum by the due date is not overdue (the rest carries interest).

public let statementDayKey = "statement_day"
public let dueDayKey = "due_day"
public let minPaymentRateKey = "min_payment_rate"
public let cardBillName = "card-bill"
/// the share of a statement taken as its minimum payment when the bank's figure is not written down
public let defaultMinPaymentRate = 0.1

/// where a bill stands
public enum CardStatus {
    /// nothing left to pay
    case settled
    /// the minimum is paid, the rest is not (not overdue; it carries interest)
    case minimumPaid
    /// not paid yet, the due date not passed
    case due
    /// past the due date with less than the minimum paid
    case overdue
}

public struct CardCycle: Identifiable {
    public var id: String { account + "|" + currency }
    public let account: String
    public let currency: String
    public let statementDay: Int
    public let dueDay: Int?
    /// the latest statement date on or before today, and the one before it
    public let statement: String
    public let previousStatement: String
    public let nextStatement: String
    /// when the latest statement must be paid (estimated 20 days after it without due_day)
    public let due: String
    public let dueEstimated: Bool
    /// owed at the statement date (0 when the card was in credit)
    public let statementAmount: Double
    /// repayments and refunds since the statement
    public let paid: Double
    /// spending since the statement (goes on the next bill)
    public let unbilled: Double
    /// owed right now
    public let balance: Double
    public let limit: Double?
    /// the minimum payment for the statement: the bank's figure (`card-bill`) or estimated
    public let minimum: Double
    public let minimumEstimated: Bool
    /// the card-bill directive the statement amount and minimum came from, if any
    public let bill: Entry?

    public var remaining: Double { max(0, roundTo(statementAmount - paid, 2)) }
    /// still to pay to reach the minimum
    public var minimumRemaining: Double { max(0, roundTo(minimum - paid, 2)) }
    public var settled: Bool { remaining < 0.005 }
    public func status(today: String) -> CardStatus {
        if settled { return .settled }
        if minimumRemaining < 0.005 { return .minimumPaid }
        return today > due ? .overdue : .due
    }
    public func overdue(today: String) -> Bool { status(today: today) == .overdue }
    public var available: Double? { limit.map { $0 - balance } }
}

/// the bank's figures for a statement: what it bills, and its minimum payment
public struct CardBill {
    public let account: String
    public let date: String
    public let amount: Double
    public let minimum: Double?
    public let currency: String
    public let entry: Entry
}

/// every card-bill directive, oldest first
public func cardBills(_ L: Ledger) -> [CardBill] {
    var out: [CardBill] = []
    for e in L.entries where e.type == .custom && e.name == cardBillName {
        var account: String?
        var amounts: [(Double, String)] = []
        for v in e.values {
            switch v {
            case .raw(let a) where account == nil: account = a
            case .string(let a) where account == nil && isAccountName(a): account = a
            case .amount(let n, let c): amounts.append((n, c))
            default: break
            }
        }
        guard let a = account, let first = amounts.first else { continue }
        let m = amounts.dropFirst().first(where: { $0.1 == first.1 })?.0
        out.append(CardBill(account: a, date: e.date, amount: abs(first.0), minimum: m.map(abs), currency: first.1, entry: e))
    }
    return out.sorted { $0.date < $1.date }
}

/// the directive for a statement's figures
public func cardBillText(card: String, statement: String, amount: Double, minimum: Double?, currency: String) -> String {
    var s = "\(statement) custom \"\(cardBillName)\" \(card) \(toFixed(amount, 2)) \(currency)"
    if let m = minimum { s += " \(toFixed(m, 2)) \(currency)" }
    return s
}

/// min_payment_rate on the open: 0.05, 5 or "5%"
func minPaymentRate(_ v: MetaValue?) -> Double {
    guard let v = v else { return defaultMinPaymentRate }
    var n: Double?
    switch v {
    case .number(let x): n = x
    default:
        let t = (v.stringValue ?? v.display).trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%") { n = Double(t.dropLast().trimmingCharacters(in: .whitespaces)).map { $0 / 100 } } else { n = Double(t) }
    }
    guard var r = n, r > 0 else { return defaultMinPaymentRate }
    if r > 1 { r /= 100 }
    return min(r, 1)
}

/// the day-of-month `d` in month "yyyy-mm", clamped to that month's last day
func dayIn(_ ym: String, _ d: Int) -> String {
    let last = Int(Day.monthEnd(ym).suffix(2)) ?? 28
    return ym + String(format: "-%02d", max(1, min(d, last)))
}

func metaInt(_ v: MetaValue?) -> Int? {
    guard let v = v else { return nil }
    switch v {
    case .number(let n): return Int(n)
    default: return Int((v.stringValue ?? v.display).trimmingCharacters(in: .whitespaces))
    }
}

/// statement date of the cycle that contains `date`
func statementOn(orAfter date: String, day: Int) -> String {
    let this = dayIn(Day.ym(date), day)
    return date <= this ? this : dayIn(Day.addMonth(Day.ym(date), 1), day)
}

func statementOn(orBefore date: String, day: Int) -> String {
    let this = dayIn(Day.ym(date), day)
    return date >= this ? this : dayIn(Day.addMonth(Day.ym(date), -1), day)
}

/// the payment due date for a statement
func dueDate(statement: String, statementDay: Int, dueDay: Int?) -> (String, Bool) {
    guard let dd = dueDay, dd >= 1, dd <= 31 else { return (Day.shift(statement, 20), true) }
    let ym = Day.ym(statement)
    let same = dayIn(ym, dd)
    return (same > statement ? same : dayIn(Day.addMonth(ym, 1), dd), false)
}

/// billing cycles for every open card with a statement_day
public func cardCycles(_ L: Ledger, today: String = Day.today()) -> [CardCycle] {
    var out: [CardCycle] = []
    let bills = cardBills(L)
    for (name, acc) in L.accounts.sorted(by: { $0.key < $1.key }) where name.hasPrefix("Liabilities:") && acc.close == nil {
        guard let sd = metaInt(acc.meta[statementDayKey]), sd >= 1, sd <= 31 else { continue }
        let dd = metaInt(acc.meta[dueDayKey])
        let ccy = acc.currencies.first ?? L.final[name]?.max(by: { abs($0.value) < abs($1.value) })?.key ?? L.base
        let st = statementOn(orBefore: today, day: sd)
        let prev = statementOn(orBefore: Day.shift(dayIn(Day.ym(st), 1), -1), day: sd)
        let next = statementOn(orAfter: Day.shift(today, 1), day: sd)
        var atStatement = 0.0, paid = 0.0, unbilled = 0.0, now = 0.0
        for t in L.txns {
            for p in t.postings where p.account == name && p.currency == ccy {
                guard let u = p.units else { continue }
                now += u
                if t.date <= st { atStatement += u }
                else if t.date <= today {
                    if u > 0 { paid += u } else { unbilled -= u }
                }
            }
        }
        let (due, est) = dueDate(statement: st, statementDay: sd, dueDay: dd)
        // the bank's figures, written for this statement (dated after the one before it, up to this one)
        let bill = bills.last { $0.account == name && $0.currency == ccy && $0.date > prev && $0.date <= st }
        let amount = bill?.amount ?? roundTo(max(0, -atStatement), 2)
        let minimum = bill?.minimum ?? roundTo(amount * minPaymentRate(acc.meta[minPaymentRateKey]), 2)
        out.append(CardCycle(account: name, currency: ccy, statementDay: sd, dueDay: dd, statement: st, previousStatement: prev,
                             nextStatement: next, due: due, dueEstimated: est,
                             statementAmount: amount, paid: roundTo(paid, 2),
                             unbilled: roundTo(unbilled, 2), balance: roundTo(-now, 2),
                             limit: creditLimit(acc.meta[creditLimitKey], ccy),
                             minimum: min(minimum, amount), minimumEstimated: bill?.minimum == nil, bill: bill?.entry))
    }
    return out
}

/// the transaction for paying a card from another account
public func repaymentText(card: String, from: String, amount: Double, currency: String, date: String) -> String {
    let n = toFixed(amount, 2)
    return alignText("\(date) * \"\(tr("信用卡还款", "Card repayment"))\" \(quoted(acctLabel(card)))\n  \(card)  \(n) \(currency)\n  \(from)  -\(n) \(currency)")
}

/// the account's display name (`name:` metadata) or its short form
public func accountTitle(_ L: Ledger, _ a: String) -> String {
    if let v = L.accounts[a]?.meta["name"] { let s = v.stringValue ?? v.display; if !s.isEmpty { return s } }
    return acctLabel(a)
}

/// the account most often used to pay this card (by past transfers into it), if any
public func usualRepaymentAccount(_ card: String, _ L: Ledger) -> String? {
    var n: [String: Int] = [:]
    for t in L.txns.suffix(3000) where t.postings.contains(where: { $0.account == card && ($0.units ?? 0) > 0 }) {
        for p in t.postings where p.account.hasPrefix("Assets:") && (p.units ?? 0) < 0 { n[p.account, default: 0] += 1 }
    }
    return n.max { $0.value < $1.value }?.key
}

/// the `open` directive the account editor writes. `keep` is the directive being edited: its other metadata
/// stays, the name and the settings made in the editor are written afresh
public func openDirectiveText(date: String, account: String, currencies: [String], booking: String, name: String,
                              creditLimit: Double?, allowNegative: Bool, statementDay: Int, dueDay: Int, keep: String?) -> String {
    var head = "\(date) open \(account)"
    if !currencies.isEmpty { head += String(repeating: " ", count: max(1, 56 - head.count)) + currencies.joined(separator: ",") }
    if !booking.isEmpty { head += " " + quoted(booking) }
    var lines = [head]
    let shown = oneLine(name)
    if !shown.isEmpty { lines.append("  name: " + quoted(shown)) }
    if account.hasPrefix("Liabilities:") || account.hasPrefix("Assets:"), statementDay > 0 { lines.append("  \(statementDayKey): \(statementDay)") }
    if account.hasPrefix("Liabilities:"), dueDay > 0 { lines.append("  \(dueDayKey): \(dueDay)") }
    if account.hasPrefix("Assets:"), allowNegative { lines.append("  \(allowNegativeKey): TRUE") }
    if account.hasPrefix("Liabilities:"), let v = creditLimit, v > 0 { lines.append("  \(creditLimitKey): \(jsNumberString(v))") }
    for l in (keep ?? "").components(separatedBy: "\n").dropFirst() {
        let t = l.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("name:") || t.hasPrefix(creditLimitKey + ":") || t.hasPrefix(allowNegativeKey + ":")
            || t.hasPrefix(statementDayKey + ":") || t.hasPrefix(dueDayKey + ":") || t.isEmpty { continue }
        lines.append(l)
    }
    return lines.joined(separator: "\n")
}
