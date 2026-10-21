import Foundation

public struct ImportChoice: Codable, Equatable {
    public var id: Int
    public var include: Bool
    public var account: String
    public var funding: String
    public var manual: Bool
    public init(id: Int, include: Bool, account: String, funding: String, manual: Bool) {
        self.id = id; self.include = include; self.account = account; self.funding = funding; self.manual = manual
    }
}

/// Recheck against the current ledger after restoring a checkpoint. In particular, a crash after local
/// commit but before checkpoint persistence must not import the same row again.
public func resumeImportChoices(_ choices: [ImportChoice], rows: [ImportRow], ledger: Ledger) -> [ImportChoice] {
    let saved = Dictionary(choices.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    let duplicate = findDuplicates(rows.map { (row: $0, funding: saved[$0.id]?.funding) }, ledger)
    return rows.enumerated().compactMap { index, row in
        guard var choice = saved[row.id] else { return nil }
        choice.include = choice.include && duplicate[index] == nil && row.direction != .neutral
        return choice
    }
}
