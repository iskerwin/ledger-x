import Foundation

// MARK: - turning the pending queue into one commit
//
// The queue holds edits (insert this entry, replace that block, write this file…), not file contents, so a
// change made on this device can be applied again on top of whatever another device pushed meanwhile.
// `planPush` decides, from the files as they are on the server now, what the commit will hold and which
// edits can no longer be applied as meant. It does no I/O, so every conflict case can be tested.

/// one file in the commit: its new text, or nil to delete it
public struct PlannedChange: Equatable {
    public let path: String
    public let text: String?
}

public struct PushPlan: Equatable {
    /// files to write or delete, in the order their first edit was queued
    public var changes: [PlannedChange] = []
    /// edits carried by `changes` (they leave the queue once the commit lands)
    public var included: [UUID] = []
    /// edits that would undo or lose someone else's change: kept on this device with the reason, not pushed
    public var failed: [UUID: String] = [:]
}

/// `ops`: the queue in order (edits already failed or held are left out by the caller or skipped here);
/// `bases`: each touched file as it is on the server now, nil when it doesn't exist.
public func planPush(_ ops: [Op], bases: [String: String?]) -> PushPlan {
    var plan = PushPlan()
    let live = ops.filter { $0.failed == nil && $0.held == nil }
    var paths: [String] = []
    for o in live where !paths.contains(o.path) { paths.append(o.path) }

    for path in paths {
        let fileOps = live.filter { $0.path == path }
        let base: String? = bases[path] ?? nil
        var text: String? = base
        var ok: [UUID] = []
        var touched = false

        var i = 0
        while i < fileOps.count {
            let o = fileOps[i]
            switch o.kind {
            case .deleteFile:
                // only the file this device created and nobody has written to since
                if let cur = text, let expected = o.old, cur != expected {
                    plan.failed[o.id] = tr("\(path) 在别处被修改过，没有删除", "\(path) was changed elsewhere and was not deleted")
                } else {
                    if text != nil { touched = true }
                    text = nil
                    ok.append(o.id)
                }
            case .write:
                let cur = text ?? ""
                if let expected = o.old, cur != expected {
                    // made against an older copy: merge when the file is ledger-x.json and the changes don't overlap
                    if path == LedgerXConfig.path, let merged = mergeConfigJSON(base: expected, mine: o.text ?? "", theirs: cur) {
                        text = merged; touched = true; ok.append(o.id)
                    } else {
                        plan.failed[o.id] = tr("\(path) 在别处被修改过，本次修改没有提交（\(o.label ?? "")）",
                                               "\(path) was changed elsewhere; this change was not pushed (\(o.label ?? ""))")
                    }
                } else {
                    text = o.text ?? ""; touched = true; ok.append(o.id)
                }
            case .remove, .replace:
                // the entry being changed must still be there as it was
                if let r = applyRemove(text ?? "", o) {
                    text = r; touched = true; ok.append(o.id)
                } else {
                    let what = (o.label ?? "").hasPrefix(tr("删除", "Delete")) || o.kind == .remove ? tr("删除", "deletion") : tr("修改", "change")
                    plan.failed[o.id] = tr("原交易已在别处被修改，本次\(what)未提交", "The entry was changed elsewhere; this \(what) was not pushed")
                    // the entry that takes its place (an edit that moved it to another day) goes with it
                    if i + 1 < fileOps.count, fileOps[i + 1].silent == true, [.insert, .balance].contains(fileOps[i + 1].kind) {
                        plan.failed[fileOps[i + 1].id] = plan.failed[o.id]
                        i += 1
                    }
                }
            default:
                text = (try? applyOps(text ?? "", path: path, ops: [o])) ?? text
                touched = true
                ok.append(o.id)
            }
            i += 1
        }
        guard !ok.isEmpty else { continue }
        plan.included += ok
        if touched && text != base { plan.changes.append(PlannedChange(path: path, text: text)) }
    }
    return plan
}

/// Three-way merge of ledger-x.json, one top-level key at a time: a key this device changed is taken from
/// `mine`, every other key from `theirs`. nil when both changed the same key differently, or a side isn't JSON.
public func mergeConfigJSON(base: String, mine: String, theirs: String) -> String? {
    func obj(_ s: String) -> [String: Any]? {
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }
    guard let b = obj(base), let m = obj(mine), let t = obj(theirs) else { return nil }
    func same(_ x: Any?, _ y: Any?) -> Bool {
        switch (x, y) {
        case (nil, nil): return true
        case let (x?, y?): return (x as? NSObject)?.isEqual(y) ?? false
        default: return false
        }
    }
    var out = t
    for k in Set(b.keys).union(m.keys) where !same(b[k], m[k]) {
        if !same(t[k], b[k]) && !same(t[k], m[k]) { return nil }   // both changed it
        out[k] = m[k]
    }
    guard let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let s = String(data: d, encoding: .utf8) else { return nil }
    // written the way LedgerXConfig.json() writes it
    return (LedgerXConfig.parse(s)?.json()) ?? (s + "\n")
}
