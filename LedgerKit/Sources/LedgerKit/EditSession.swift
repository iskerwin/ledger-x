import Foundation

/// Editor state, including incomplete values. Display-only row UUIDs don't make an edit dirty.
public struct DraftSession: Codable, Equatable {
    public var draft: Draft
    public var baseline: Draft
    public init(draft: Draft, baseline: Draft) { self.draft = draft; self.baseline = baseline }

    public var hasChanges: Bool { !sameDraftContent(draft, baseline) }
    public var shouldKeep: Bool { hasChanges || (draft.replacing == nil && draftHasContent(draft)) }
}

public func sameDraftContent(_ a: Draft, _ b: Draft) -> Bool {
    var b = b
    for i in b.rows.indices where i < a.rows.count { b.rows[i].id = a.rows[i].id }
    for i in b.shares.indices where i < a.shares.count { b.shares[i].id = a.shares[i].id }
    for i in b.extraFunds.indices where i < a.extraFunds.count { b.extraFunds[i].id = a.extraFunds[i].id }
    return a == b
}

public func draftHasContent(_ d: Draft) -> Bool {
    let values = [d.amount, d.payee, d.narration, d.raw, d.toAmount, d.paid, d.discount, d.person,
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
