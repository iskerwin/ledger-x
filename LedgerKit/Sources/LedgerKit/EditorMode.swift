import Foundation

public enum EditorConversionError: Error {
    case incomplete, notRepresentable

    public var message: String {
        switch self {
        case .incomplete:
            return tr("当前内容还不能转换，请先补全；已填内容仍保留在原模式。",
                      "Complete the entry before converting. Your input is kept in the current editor.")
        case .notRepresentable:
            return tr("目标模式无法完整保留这笔内容，请继续使用当前模式；原内容没有改变。",
                      "The target editor cannot preserve this entry completely. Your current content is unchanged.")
        }
    }
}

/// Convert the current transaction, never a stale copy of another editor. A failure leaves the caller's
/// draft untouched. Unchanged round trips restore the exact input snapshot (including numeric spelling).
public func convertingEditor(_ current: Draft, to kind: DraftKind, ledger L: Ledger, derived D: Derived,
                             previous: Draft? = nil) -> Result<Draft, EditorConversionError> {
    let blankRows = current.rows.allSatisfy { $0.account.isEmpty || $0.account == current.funding }
    if !draftHasContent(current), current.account.isEmpty, current.edited == nil, blankRows {
        var next = previous ?? current
        next.kind = kind
        next.replacing = current.replacing
        next.edited = nil
        return .success(next)
    }
    let text = draftText(current, L, D)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.incomplete) }
    if kind == .raw {
        var next = current
        next.kind = .raw
        next.raw = text
        next.edited = nil
        return .success(next)
    }
    let checked = validateText(text, L, single: true)
    guard checked.ok, let transaction = checked.txn else { return .failure(.incomplete) }
    // A visual form cannot preserve comments or directives surrounding a transaction.
    guard !text.components(separatedBy: "\n").contains(where: lineHasComment) else {
        return .failure(.notRepresentable)
    }
    if let previous = previous, previous.kind == kind {
        let old = validateText(draftText(previous, L, D), L, single: true)
        if old.ok, let original = old.txn, sameTxn(original, transaction) {
            var restored = previous
            restored.replacing = current.replacing
            return .success(restored)
        }
    }
    var next: Draft
    if kind == .multi {
        next = multiDraftFromTxn(transaction, D, defaultFunding: current.funding)
        next.date = transaction.date
        next.keepMeta = transaction.meta.items.filter { $0.0 != "filename" && $0.0 != "lineno" }
            .map { KeptMeta(key: $0.0, value: $0.1.stringValue.map(quoted) ?? $0.1.display) }
    } else {
        guard let simple = editDraft(transaction, L, D), simple.kind == kind else {
            return .failure(.notRepresentable)
        }
        next = simple
    }
    next.replacing = current.replacing
    next.refundOf = current.refundOf
    next.scan = current.scan
    next.eventsTouched = true
    next.selection = current.selection
    let back = validateText(draftText(next, L, D), L, single: true)
    guard back.ok, let regenerated = back.txn, sameTxn(transaction, regenerated) else {
        return .failure(.notRepresentable)
    }
    return .success(next)
}
