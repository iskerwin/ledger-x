import Foundation

/// File versions and operations that produced the ledger currently on screen.
public struct LedgerBuildKey: Equatable {
    public var files: [String: String]
    public var ops: [Op]

    public init(files: [String: String], ops: [Op]) {
        self.files = files
        self.ops = ops
    }
}

/// The on-screen ledger may stand in for a freshly loaded "before" only when every file was
/// downloaded and it was built from these exact versions and operations. A non-empty queue is
/// fine. Held or failed operations are not the same set, so they do not match.
public func canReuseBuiltLedger(built: LedgerBuildKey?, complete: Bool, files: [String: String], ops: [Op]) -> Bool {
    guard complete, let built else { return false }
    return built.files == files && built.ops == ops
}

/// Whether two ledger snapshots are the same text after their own operations are applied.
/// A missing path is an empty file. Callers that could not read a blob must not use this.
public func ledgerTextsMatch(paths: [String], oldTexts: [String: String], newTexts: [String: String], oldOps: [Op], newOps: [Op]) -> Bool {
    for path in paths {
        let old = (try? applyOps(oldTexts[path] ?? "", path: path, ops: oldOps)) ?? ""
        let new = (try? applyOps(newTexts[path] ?? "", path: path, ops: newOps)) ?? ""
        if old != new { return false }
    }
    return true
}
