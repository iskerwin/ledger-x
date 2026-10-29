import Foundation

/// Editor state, including incomplete values. Display-only row UUIDs don't make an edit dirty.
public struct DraftSession: Codable, Equatable {
    public var draft: Draft
    public var baseline: Draft
    public init(draft: Draft, baseline: Draft) { self.draft = draft; self.baseline = baseline }

    public var hasChanges: Bool { !sameDraftContent(draft, baseline) }
    public var shouldKeep: Bool { hasChanges || (draft.replacing == nil && draftHasContent(draft)) }

    /// The day changed while a new, untouched form was open on it: the form moves to the new day, as if opened
    /// now. A form with anything filled in, an edit, or a date picked by hand stays as it is (nil).
    public func rollingDate(from old: String, to new: String) -> DraftSession? {
        guard draft.replacing == nil, !shouldKeep, draft.date == old, old != new else { return nil }
        var draft = draft, baseline = baseline
        draft.date = new
        baseline.date = new
        return DraftSession(draft: draft, baseline: baseline)
    }

    /// A type change on an untouched creation form selects its initial layout, not a transaction edit.
    /// Preserve the original baseline once any other field has changed, including account-only input.
    public func selectingKind(_ next: Draft) -> DraftSession {
        DraftSession(draft: next, baseline: draft.replacing == nil && !shouldKeep ? next : baseline)
    }
}

public func sameDraftContent(_ a: Draft, _ b: Draft) -> Bool {
    var a = normalizedDraft(a), b = normalizedDraft(b)
    a.selection = nil; b.selection = nil
    for i in b.rows.indices where i < a.rows.count { b.rows[i].id = a.rows[i].id }
    for i in b.shares.indices where i < a.shares.count { b.shares[i].id = a.shares[i].id }
    for i in b.extraFunds.indices where i < a.extraFunds.count { b.extraFunds[i].id = a.extraFunds[i].id }
    return a == b
}

/// Whether this kind of entry can keep `account` (an expense category is not an income category).
public func draftKindFits(_ kind: DraftKind, _ account: String) -> Bool {
    switch kind {
    case .income: return account.isEmpty || account.hasPrefix("Income:")
    case .expense: return account.isEmpty || account.hasPrefix("Expenses:")
    default: return true
    }
}

/// Switch type the way the form does, but remember each type as the user left it.
/// Coming back restores that type's category and flags. Amount, date, payee, note and
/// funding edited on the other type still come along.
public func switchingKind(
    _ current: Draft,
    to kind: DraftKind,
    remembering snapshots: [DraftKind: Draft],
    fundingCurrency: String?,
    defaultCurrency: String?
) -> (draft: Draft, snapshots: [DraftKind: Draft]) {
    guard kind != current.kind else { return (current, snapshots) }
    var snapshots = snapshots
    snapshots[current.kind] = current
    var next = current
    next.kind = kind
    next.edited = nil
    if kind == .transfer { next.currency = fundingCurrency ?? next.currency }
    else if kind != .multi, let defaultCurrency { next.currency = defaultCurrency }
    if kind == .multi && !next.rows.contains(where: { !$0.account.isEmpty }) {
        next.rows = [DraftRow(), DraftRow(account: next.funding, currency: fundingCurrency ?? "CNY")]
    }
    if !draftKindFits(kind, next.account) {
        next.account = ""
        if next.selection != nil { next.selection?.category = false }
    }
    if kind != .expense {
        next.reimb = false
        next.split = false
        next.shares = []
        next.extraFunds = []
        next.discount = ""
        if isFloatLink(trimmedDraft(next.link)) { next.link = "" }
    }
    if let saved = snapshots[kind] {
        next = carryingSharedFields(from: current, onto: saved)
        next.kind = kind
        next.edited = nil
    }
    return (next, snapshots)
}

/// The fields that stay on screen for 支出, 收入 and 转账.
func carryingSharedFields(from current: Draft, onto saved: Draft) -> Draft {
    var draft = saved
    draft.date = current.date
    draft.payee = current.payee
    draft.narration = current.narration
    draft.amount = current.amount
    draft.funding = current.funding
    draft.flag = current.flag
    return draft
}

func normalizedDraft(_ draft: Draft) -> Draft {
    var d = draft
    d.targetCurrency = d.targetCurrency.flatMap { trimmedDraft($0).isEmpty ? nil : trimmedDraft($0) }
    d.transferFee = d.transferFee.flatMap { trimmedDraft($0).isEmpty ? nil : canonicalAmount($0) }
    d.feeCurrency = d.feeCurrency.flatMap { trimmedDraft($0).isEmpty ? nil : trimmedDraft($0) }
    d.feeFunding = d.feeFunding.flatMap { trimmedDraft($0).isEmpty ? nil : trimmedDraft($0) }
    if d.transferFee == nil || evalAmount(d.transferFee ?? "") == 0 {
        d.feeMode = nil; d.feeFunding = nil; d.feeCurrency = nil
    }
    d.payee = trimmedDraft(d.payee)
    d.narration = trimmedDraft(d.narration)
    d.account = trimmedDraft(d.account)
    d.funding = trimmedDraft(d.funding)
    d.to = trimmedDraft(d.to)
    d.person = trimmedDraft(d.person)
    d.link = trimmedDraft(d.link)
    d.tagsText = trimmedDraft(d.tagsText)
    d.voucher = trimmedDraft(d.voucher)
    d.raw = trimmedDraft(d.raw)
    d.amount = canonicalAmount(d.amount)
    d.toAmount = canonicalAmount(d.toAmount)
    d.paid = canonicalAmount(d.paid)
    d.discount = canonicalAmount(d.discount)
    d.rate = canonicalAmount(d.rate)
    for i in d.rows.indices {
        d.rows[i].account = trimmedDraft(d.rows[i].account)
        d.rows[i].amount = canonicalAmount(d.rows[i].amount)
        d.rows[i].cost = trimmedDraft(d.rows[i].cost)
        d.rows[i].price = trimmedDraft(d.rows[i].price)
        d.rows[i].person = trimmedDraft(d.rows[i].person)
    }
    for i in d.shares.indices {
        d.shares[i].person = trimmedDraft(d.shares[i].person)
        d.shares[i].amount = canonicalAmount(d.shares[i].amount)
    }
    for i in d.extraFunds.indices {
        d.extraFunds[i].account = trimmedDraft(d.extraFunds[i].account)
        d.extraFunds[i].amount = canonicalAmount(d.extraFunds[i].amount)
    }
    return d
}

/// "25" and "25.00" are the same amount. An expression such as "12+" stays as typed.
func canonicalAmount(_ text: String) -> String {
    let t = trimmedDraft(text)
    guard t.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil, let n = Double(t) else { return t }
    return jsNumberString(n)
}

func trimmedDraft(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}

public func draftHasContent(_ d: Draft) -> Bool {
    let values = [d.amount, d.payee, d.narration, d.raw, d.toAmount, d.paid, d.discount, d.person, d.transferFee ?? "",
                  d.link, d.tagsText, d.rate, d.voucher]
    return values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        || !d.tags.isEmpty || !d.shares.isEmpty || !d.extraFunds.isEmpty
        || d.rows.contains { !$0.amount.isEmpty || !$0.cost.isEmpty || !$0.price.isEmpty || !$0.person.isEmpty }
}

public struct SourceEditSession: Codable, Equatable {
    public let file: String
    public let original: String
    public var text: String
    public let label: String
    public init(file: String, original: String, text: String, label: String) {
        self.file = file; self.original = original; self.text = text; self.label = label
    }
    public var hasChanges: Bool { normEntryText(alignText(text)) != normEntryText(alignText(original)) }
}

/// One workspace per ledger. Editing an existing entry never overwrites the new-entry draft.
public struct DraftWorkspace: Codable, Equatable {
    public var creation: DraftSession?
    public var edits: [String: DraftSession] = [:]
    public var sources: [String: SourceEditSession] = [:]
    public init() {}

    public static func editKey(_ r: Replacing) -> String {
        sourceKey(file: r.path, original: r.old)
    }

    public static func sourceKey(file: String, original: String) -> String {
        // JSON framing avoids collisions between paths and source strings containing separators.
        String(data: try! JSONEncoder().encode([file, original]), encoding: .utf8)!
    }

    public mutating func remember(_ session: SourceEditSession) {
        let key = Self.sourceKey(file: session.file, original: session.original)
        sources[key] = session.hasChanges ? session : nil
    }

    public mutating func remember(_ session: DraftSession) {
        if let r = session.draft.replacing {
            let key = Self.editKey(r)
            edits[key] = session.hasChanges ? session : nil
        } else { creation = session.shouldKeep ? session : nil }
    }

    public mutating func forget(_ draft: Draft) {
        if let r = draft.replacing { edits[Self.editKey(r)] = nil }
        else { creation = nil }
    }

    public func session(for initial: Draft) -> DraftSession {
        guard let r = initial.replacing, let saved = edits[Self.editKey(r)] else {
            return DraftSession(draft: initial, baseline: initial)
        }
        return saved
    }
}

/// Serializable page controls, independent from navigation destinations and ledger data.
public struct BrowseContext: Codable, Equatable {
    public var query = ""
    public var filters: [String] = []
    public var limit = 150
    public var month = Day.ym(Day.today())
    public var opened: [String: Bool] = [:]
    public var anchor: String?
    public init() {}
}

/// A jump from 报表 or an account into 明细. The browse it replaces is kept, so it can be put back.
public struct JournalLink: Equatable {
    public enum Kind: Equatable {
        /// this month and category, written as a search 明细 already understands
        case report(month: String, account: String)
        /// this account's transactions, with no leftover search
        case account(String)
    }

    public var kind: Kind
    /// what 明细 was showing before the first jump
    public var previous: BrowseContext

    public init(kind: Kind, previous: BrowseContext) {
        self.kind = kind
        self.previous = previous
    }

    /// the browse 明细 should show for this jump
    public var browse: BrowseContext {
        var next = BrowseContext()
        next.limit = max(150, previous.limit)
        switch kind {
        case .report(let month, let account):
            let month = journalText(month), account = journalText(account)
            var parts: [String] = []
            if !month.isEmpty { parts.append(month) }
            if !account.isEmpty { parts.append("科目:" + account) }
            next.query = parts.joined(separator: " ")
        case .account(let name):
            let name = journalText(name)
            next.anchor = name.isEmpty ? nil : name
        }
        return next
    }
}

/// Remember the first browse. A later jump keeps that original, so going back
/// returns to what the user had open, not to the jump in between.
public func journalLink(_ kind: JournalLink.Kind, from current: BrowseContext, previous: BrowseContext?) -> JournalLink {
    JournalLink(kind: kind, previous: previous ?? current)
}

private func journalText(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// What an already-loaded list should say. Loading, failure and retry stay on the root screen.
public enum BrowseEmpty: Equatable {
    case showing
    /// the ledger or account has nothing to list
    case nothingHere
    /// a search or filter removed every row
    case nothingMatches
}

public func browseEmpty(count: Int, filtered: Bool) -> BrowseEmpty {
    if count > 0 { return .showing }
    return filtered ? .nothingMatches : .nothingHere
}

/// Apply recommendations without replacing choices explicitly made in either editor.
public func applyingSuggestedAccounts(_ draft: Draft, category: String?, funding: String?) -> Draft {
    var d = draft
    if d.selection?.category != true, d.replacing == nil || d.account.isEmpty, let category = category { d.account = category }
    if d.selection?.funding != true, d.replacing == nil || d.funding.isEmpty, let funding = funding { d.funding = funding }
    return d
}

