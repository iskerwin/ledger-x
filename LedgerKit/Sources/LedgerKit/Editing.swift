import Foundation

// 可视化编辑: an entry already in the ledger, opened in the 记一笔 form. Only when the form writes it back
// exactly as it is (same accounts, amounts, prices, tags, links and metadata) — otherwise its source is edited.

/// the form for editing `t`, or nil when the form can't hold all of it (then only the source is edited).
/// The simple form is tried first, the split form (分录) next.
public func editDraft(_ t: Entry, _ L: Ledger, _ D: Derived) -> Draft? {
    guard t.type == .txn, !t.synthetic else { return nil }
    // comments would be lost
    if t.src.components(separatedBy: "\n").contains(where: { lineHasComment($0) }) { return nil }
    let eventTags = Set(ledgerEvents(L).map { $0.tag })
    var tries: [Draft] = []
    if !isComplex(t) { tries.append(draftFromTxn(t, L, D, defaultFunding: nil)) }
    tries.append(multiDraftFromTxn(t, D, defaultFunding: nil))
    for var d in tries {
        d.date = t.date
        d.flag = t.flag == "!" ? "!" : "*"
        let exchange = d.kind == .transfer && !d.toAmount.isEmpty
        if d.kind != .multi {
            // the form's own tags come back from what it shows (报销, 退款, 转账 / 换汇, events); the rest are kept
            let own: Set<String> = ["reimbursed", "refund", "transfer", "fx"]
            d.events = t.tags.filter { eventTags.contains($0) }
            d.eventsTouched = true
            d.tags = t.tags.filter { !eventTags.contains($0) && !own.contains($0) }
            if d.kind == .transfer {
                // keep the payee and description as written (the form would make up new ones)
                d.payee = t.payee; d.narration = t.narration
                if t.tags.contains("transfer") { d.tags.insert("transfer", at: 0) }
            }
            d.topup = metaTrue(t.meta[subTopupMeta])
            // the link the form shows: the reimbursement or petty cash on an advance, else a subscription's
            d.link = d.reimb ? (t.links.first { $0.hasPrefix("float-") || $0.hasPrefix("reimburse") } ?? "")
                : d.kind == .transfer ? "" : (t.links.first { $0.hasPrefix("sub-") } ?? "")
            let shown = d.link.trimmingCharacters(in: .whitespaces)
            d.keepLinks = t.links.filter { $0 != shown }
            if exchange, let r = t.meta["exchange_rate"].map({ $0.stringValue ?? $0.display }),
               let a = evalAmount(d.amount), let ta = evalAmount(d.toAmount) {
                d.fxRate = KeptRate(text: r, amount: a, toAmount: ta)
            }
        }
        let regenerated: Set<String> = Set(["filename", "lineno"] + (d.kind != .multi ? [subTopupMeta] : []) + (exchange ? ["exchange_rate"] : []))
        d.keepMeta = t.meta.items.filter { !regenerated.contains($0.0) }.map { KeptMeta(key: $0.0, value: $0.1.stringValue.map(quoted) ?? $0.1.display) }
        let text = draftText(d, L, D)
        guard !text.isEmpty, let back = checkText(text, L).entries.first(where: { $0.type == .txn }),
              sameTxn(t, back) else { continue }
        return d
    }
    return nil
}

/// a `;` outside quotes
func lineHasComment(_ l: String) -> Bool {
    var q = false
    for ch in l {
        if ch == "\"" { q.toggle() } else if ch == ";" && !q { return true }
    }
    return false
}

/// the same entry, however it is laid out: header, tags, links, metadata, and every posting after booking
/// (account, units, currency, cost, what it weighs in the other currency, its metadata)
public func sameTxn(_ a: Entry, _ b: Entry, ignoring: Set<String> = []) -> Bool {
    func meta(_ m: Meta) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in m.items where k != "filename" && k != "lineno" && !ignoring.contains(k) { out[k] = v.stringValue ?? v.display }
        return out
    }
    func key(_ p: Posting) -> String {
        let w = weight(p)
        let cost = p.cost.map { "\(toFixed($0.number ?? 0, 6)) \($0.currency ?? "")" } ?? ""
        return [p.account, toFixed(p.units ?? 0, 6), p.currency ?? "", cost,
                w.map { "\(toFixed($0.n, 2)) \($0.c)" } ?? "", p.flag ?? "",
                meta(p.meta).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")]
            .joined(separator: "|")
    }
    return a.date == b.date && a.flag == b.flag && a.payee == b.payee && a.narration == b.narration
        && Set(a.tags) == Set(b.tags) && Set(a.links) == Set(b.links) && meta(a.meta) == meta(b.meta)
        && a.postings.map(key).sorted() == b.postings.map(key).sorted()
}
