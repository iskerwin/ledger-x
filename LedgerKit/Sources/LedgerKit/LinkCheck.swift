import Foundation

// Links (^…) tie transactions together: a refund and its purchase, advances and the reimbursement
// that pays them back, the charges of one subscription. A link that lost its other half, or
// a group whose amounts do not add up, is usually a mistake worth pointing out.

public enum LinkRole: String {
    case refund, reimburse, subscription, other

    public static func of(_ link: String) -> LinkRole {
        if link.hasPrefix("refund") { return .refund }
        if link.hasPrefix("reimburse") { return .reimburse }
        if link.hasPrefix("sub-") { return .subscription }
        return .other
    }

    public var title: String {
        switch self {
        case .refund: return tr("退款", "Refund")
        case .reimburse: return tr("报销", "Reimbursement")
        case .subscription: return tr("订阅", "Subscription")
        case .other: return tr("自定义", "Custom")
        }
    }
}

public struct LinkIssue: Identifiable {
    public enum Kind: String {
        case refundAlone, refundNoPurchase, refundExceeds, refundAccount
        case reimburseNoAdvance, reimburseUnbalanced
        case subUnknown, subAccount
        case single
        case refundUnlinked, reimbursementUnlinked
    }
    public let kind: Kind
    /// nil for the "should have a link" issues
    public let link: String?
    public let txn: Entry
    public let detail: String

    public var id: String { kind.rawValue + "|" + (link ?? "") + "|" + txn.file + ":\(txn.line)|" + txn.date }
    /// a stable id that survives edits elsewhere in the file (used to ignore an issue)
    public var key: String { kind.rawValue + "|" + (link ?? "") + "|" + txn.date + "|" + txn.payee + "|" + txn.narration }

    public var isError: Bool {
        switch kind {
        case .refundAlone, .refundNoPurchase, .reimburseNoAdvance, .subUnknown: return true
        default: return false
        }
    }

    public var title: String {
        switch kind {
        case .refundAlone: return tr("退款链接只有这一笔", "Refund link is on this transaction only")
        case .refundNoPurchase: return tr("找不到退款对应的原交易", "The refunded purchase is missing")
        case .refundExceeds: return tr("退款金额大于原交易", "Refunds exceed the purchase")
        case .refundAccount: return tr("退款与原交易的科目不同", "Refund and purchase use different accounts")
        case .reimburseNoAdvance: return tr("报销回款找不到垫付", "Reimbursement has no advances")
        case .reimburseUnbalanced: return tr("报销回款与垫付不一致", "Reimbursement does not match the advances")
        case .subUnknown: return tr("订阅链接没有对应的订阅", "Subscription link has no subscription")
        case .subAccount: return tr("扣费科目与订阅不一致", "Charge account differs from the subscription")
        case .single: return tr("链接只出现在这一笔", "Link appears on this transaction only")
        case .refundUnlinked: return tr("退款未关联原交易", "Refund not linked to a purchase")
        case .reimbursementUnlinked: return tr("报销回款未关联垫付", "Reimbursement not linked to advances")
        }
    }
}

/// a figure shown under a link group (原价 / 已退 / 净支出 …), in the base currency
public struct LinkFigure: Identifiable {
    public var id: String { label }
    public let label: String
    public let value: Double
}

func expenseValue(_ t: Entry, _ L: Ledger) -> Double {
    var v = 0.0
    for p in t.postings where p.account.hasPrefix("Expenses:") {
        if let u = p.units, let c = p.currency { v += toCNY(L, u, c, t.date) ?? 0 }
    }
    return v
}

func receivableValues(_ t: Entry, _ L: Ledger) -> (plus: Double, minus: Double) {
    var plus = 0.0, minus = 0.0
    for p in t.postings where p.account.hasPrefix("Assets:Receivable") {
        guard let u = p.units, let c = p.currency else { continue }
        let v = toCNY(L, u, c, t.date) ?? 0
        if v > 0 { plus += v } else { minus -= v }
    }
    return (plus, minus)
}

/// totals for one link's transactions
public func linkFigures(_ link: String, _ entries: [Entry], _ L: Ledger) -> [LinkFigure] {
    switch LinkRole.of(link) {
    case .refund:
        let vs = entries.map { expenseValue($0, L) }
        let paid = vs.filter { $0 > 0 }.reduce(0, +), back = -vs.filter { $0 < 0 }.reduce(0, +)
        guard paid > 0 || back > 0 else { return [] }
        return [LinkFigure(label: tr("原价", "Paid"), value: roundTo(paid, 2)),
                LinkFigure(label: tr("已退", "Refunded"), value: roundTo(back, 2)),
                LinkFigure(label: tr("净支出", "Net"), value: roundTo(paid - back, 2))]
    case .reimburse:
        var plus = 0.0, minus = 0.0
        for t in entries { let r = receivableValues(t, L); plus += r.plus; minus += r.minus }
        guard plus > 0 || minus > 0 else { return [] }
        return [LinkFigure(label: tr("垫付", "Advanced"), value: roundTo(plus, 2)),
                LinkFigure(label: tr("已回款", "Paid back"), value: roundTo(minus, 2)),
                LinkFigure(label: tr("待回款", "Outstanding"), value: roundTo(plus - minus, 2))]
    case .subscription, .other:
        let total = entries.reduce(0.0) { $0 + expenseValue($1, L) }
        return abs(total) > 0.005 ? [LinkFigure(label: tr("合计支出", "Total spent"), value: roundTo(total, 2))] : []
    }
}

/// every link problem in the ledger, errors first
public func linkIssues(_ L: Ledger, subscriptions subs: [Subscription]) -> [LinkIssue] {
    var byLink: [String: [Entry]] = [:]
    var order: [String] = []
    for t in L.txns where !t.synthetic {
        for l in t.links {
            if byLink[l] == nil { order.append(l) }
            if !(byLink[l]?.contains { $0 === t } ?? false) { byLink[l, default: []].append(t) }
        }
    }
    let subByLink = Dictionary(subs.map { ($0.link, $0) }, uniquingKeysWith: { a, _ in a })
    var out: [LinkIssue] = []

    for l in order {
        let ts = byLink[l] ?? []
        switch LinkRole.of(l) {
        case .refund:
            if ts.count == 1 { out.append(LinkIssue(kind: .refundAlone, link: l, txn: ts[0], detail: "^" + l)); continue }
            let vals = ts.map { ($0, expenseValue($0, L)) }
            let purchases = vals.filter { $0.1 > 0.005 }, refunds = vals.filter { $0.1 < -0.005 }
            if purchases.isEmpty {
                for r in refunds { out.append(LinkIssue(kind: .refundNoPurchase, link: l, txn: r.0, detail: "^" + l)) }
                continue
            }
            let paid = purchases.reduce(0) { $0 + $1.1 }, back = -refunds.reduce(0) { $0 + $1.1 }
            if back > paid + 0.01, let last = refunds.last {
                out.append(LinkIssue(kind: .refundExceeds, link: l, txn: last.0,
                                     detail: String(format: tr("原价 %@，已退 %@", "Paid %@, refunded %@"), fmtNum(roundTo(paid, 2), 2), fmtNum(roundTo(back, 2), 2))))
            }
            let bought = Set(purchases.flatMap { $0.0.postings.filter { $0.account.hasPrefix("Expenses:") }.map { $0.account } })
            for r in refunds {
                let accts = Set(r.0.postings.filter { $0.account.hasPrefix("Expenses:") }.map { $0.account })
                if !accts.isEmpty && accts.isDisjoint(with: bought) {
                    out.append(LinkIssue(kind: .refundAccount, link: l, txn: r.0,
                                         detail: accts.sorted().joined(separator: ", ") + " ≠ " + bought.sorted().joined(separator: ", ")))
                }
            }
        case .reimburse:
            var plus = 0.0, minus = 0.0
            var payout: Entry?
            for t in ts {
                let r = receivableValues(t, L)
                plus += r.plus; minus += r.minus
                if r.minus > 0 { payout = t }
            }
            if let p = payout {
                if plus < 0.005 {
                    out.append(LinkIssue(kind: .reimburseNoAdvance, link: l, txn: p, detail: "^" + l))
                } else if abs(plus - minus) > 0.01 {
                    out.append(LinkIssue(kind: .reimburseUnbalanced, link: l, txn: p,
                                         detail: String(format: tr("垫付 %@，回款 %@", "Advanced %@, paid back %@"), fmtNum(roundTo(plus, 2), 2), fmtNum(roundTo(minus, 2), 2))))
                }
            } else if ts.count == 1 && plus < 0.005 {
                out.append(LinkIssue(kind: .single, link: l, txn: ts[0], detail: "^" + l))
            }
        case .subscription:
            guard let s = subByLink[l] else {
                for t in ts { out.append(LinkIssue(kind: .subUnknown, link: l, txn: t, detail: "^" + l)) }
                continue
            }
            guard !s.account.isEmpty else { continue }
            for t in ts where !t.postings.contains(where: { $0.account == s.account }) {
                let accts = t.postings.filter { $0.account.hasPrefix("Expenses:") }.map { $0.account }
                guard !accts.isEmpty else { continue }
                out.append(LinkIssue(kind: .subAccount, link: l, txn: t, detail: accts.joined(separator: ", ") + " ≠ " + s.account))
            }
        case .other:
            if ts.count == 1 { out.append(LinkIssue(kind: .single, link: l, txn: ts[0], detail: "^" + l)) }
        }
    }

    for t in L.txns where !t.synthetic {
        if t.tags.contains("refund") && !t.links.contains(where: { $0.hasPrefix("refund") }) {
            out.append(LinkIssue(kind: .refundUnlinked, link: nil, txn: t, detail: "#refund"))
        }
        if t.tags.contains("reimbursement") && !t.links.contains(where: { $0.hasPrefix("reimburse") }) {
            out.append(LinkIssue(kind: .reimbursementUnlinked, link: nil, txn: t, detail: "#reimbursement"))
        }
    }
    return out.sorted { a, b in
        if a.isError != b.isError { return a.isError }
        return a.txn.date > b.txn.date
    }
}

/// the transaction's text with `link` added to (or, with `remove`, taken off) its header line
public func headerLinkEdit(_ src: String, link: String, remove: Bool) -> String {
    var lines = src.components(separatedBy: "\n")
    guard let i = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return src }
    if remove {
        var words = lines[i].components(separatedBy: " ")
        words.removeAll { $0 == "^" + link }
        lines[i] = words.joined(separator: " ")
    } else if !lines[i].split(whereSeparator: { $0 == " " || $0 == "\t" }).contains(where: { String($0) == "^" + link }) {
        // before a trailing comment, if any
        let lastQuote = lines[i].range(of: "\"", options: .backwards)?.upperBound ?? lines[i].startIndex
        if let r = lines[i].range(of: " ;", range: lastQuote..<lines[i].endIndex) {
            lines[i] = String(lines[i][..<r.lowerBound]).trimmingCharacters(in: .whitespaces) + " ^" + link + " " + String(lines[i][r.lowerBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            lines[i] = lines[i].replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + " ^" + link
        }
    }
    return lines.joined(separator: "\n")
}
