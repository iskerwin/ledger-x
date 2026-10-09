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

public let statementDayKey = "statement_day"
public let dueDayKey = "due_day"

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

    public var remaining: Double { max(0, roundTo(statementAmount - paid, 2)) }
    public var settled: Bool { remaining < 0.005 }
    public func overdue(today: String) -> Bool { !settled && today > due }
    public var available: Double? { limit.map { $0 - balance } }
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
        out.append(CardCycle(account: name, currency: ccy, statementDay: sd, dueDay: dd, statement: st, previousStatement: prev,
                             nextStatement: next, due: due, dueEstimated: est,
                             statementAmount: roundTo(max(0, -atStatement), 2), paid: roundTo(paid, 2),
                             unbilled: roundTo(unbilled, 2), balance: roundTo(-now, 2),
                             limit: creditLimit(acc.meta[creditLimitKey], ccy)))
    }
    return out
}

/// the transaction for paying a card from another account
public func repaymentText(card: String, from: String, amount: Double, currency: String, date: String) -> String {
    let n = toFixed(amount, 2)
    return alignText("\(date) * \"\(tr("信用卡还款", "Card repayment"))\" \(quoted(acctLabel(card)))\n  \(card)  \(n) \(currency)\n  \(from)  -\(n) \(currency)")
}

/// the account most often used to pay this card (by past transfers into it), if any
public func usualRepaymentAccount(_ card: String, _ L: Ledger) -> String? {
    var n: [String: Int] = [:]
    for t in L.txns.suffix(3000) where t.postings.contains(where: { $0.account == card && ($0.units ?? 0) > 0 }) {
        for p in t.postings where p.account.hasPrefix("Assets:") && (p.units ?? 0) < 0 { n[p.account, default: 0] += 1 }
    }
    return n.max { $0.value < $1.value }?.key
}
