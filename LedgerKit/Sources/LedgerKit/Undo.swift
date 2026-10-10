import Foundation

/// One change the app made to the ledger, kept so it can be taken back later.
/// Only the changed regions are stored (as ops that restore them), not whole files.
public struct ChangeRecord: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var time: Date
    public var label: String
    public var files: [String]
    /// ops that put the changed regions back the way they were
    public var undo: [Op]
    /// set once the change has been taken back
    public var undone: Date?

    public init(time: Date = Date(), label: String, files: [String], undo: [Op]) {
        self.time = time; self.label = label; self.files = files; self.undo = undo
    }
}

/// a changed region of a file: what the change replaced (`before`) and what it wrote (`after`),
/// with the same context lines around both
public struct ChangeHunk: Equatable {
    public let path: String
    public let context: (before: [String], after: [String])
    public let removed: [String]
    public let added: [String]
    public static func == (a: ChangeHunk, b: ChangeHunk) -> Bool {
        a.path == b.path && a.removed == b.removed && a.added == b.added && a.context.before == b.context.before && a.context.after == b.context.after
    }
}

private func trimEnd(_ s: String) -> String {
    var x = Substring(s)
    while let last = x.unicodeScalars.last, last == " " || last == "\t" || last == "\r" { x = x.dropLast() }
    return String(x)
}

/// line ranges that differ between `a` and `b`, in order
func lineHunks(_ a: [String], _ b: [String]) -> [(a: Range<Int>, b: Range<Int>)] {
    var p = 0
    while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
    var s = 0
    while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
    let am = Array(a[p..<(a.count - s)]), bm = Array(b[p..<(b.count - s)])
    if am.isEmpty && bm.isEmpty { return [] }
    let n = am.count, m = bm.count
    // one region when either side is empty, or too big to diff line by line (a rename touching the whole file)
    if n == 0 || m == 0 || n * m > 2_000_000 { return [(p..<(p + n), p..<(p + m))] }
    // longest common subsequence, then walk it to collect the differing runs
    var L = [Int32](repeating: 0, count: (n + 1) * (m + 1))
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
            L[i * (m + 1) + j] = am[i] == bm[j] ? L[(i + 1) * (m + 1) + j + 1] + 1
                : max(L[(i + 1) * (m + 1) + j], L[i * (m + 1) + j + 1])
        }
    }
    var out: [(a: Range<Int>, b: Range<Int>)] = []
    var i = 0, j = 0, ha = 0, hb = 0, open = false
    func close() { if open { out.append((p + ha..<p + i, p + hb..<p + j)); open = false } }
    while i < n || j < m {
        if i < n, j < m, am[i] == bm[j] { close(); i += 1; j += 1; continue }
        if !open { open = true; ha = i; hb = j }
        if j < m, i == n || L[i * (m + 1) + j + 1] >= L[(i + 1) * (m + 1) + j] { j += 1 } else { i += 1 }
    }
    close()
    return out
}

private func occurrences(_ block: [String], in lines: [String]) -> Int {
    guard !block.isEmpty, block.count <= lines.count else { return 0 }
    let want = block.map(trimEnd), have = lines.map(trimEnd)
    var n = 0
    for i in 0...(have.count - block.count) {
        var ok = true
        for k in 0..<want.count where have[i + k] != want[k] { ok = false; break }
        if ok { n += 1; if n > 1 { return n } }
    }
    return n
}

/// ops that turn `after` back into `before` for one file; nil means the file did not exist.
/// Each changed region becomes a `.replace` of the new text (with enough context to be unique)
/// by the old text, so it still applies when other parts of the file changed since.
public func revertOps(path: String, before: String?, after: String?) -> [Op] {
    if before == after { return [] }
    guard let after = after else {
        var op = Op(kind: .write, path: path); op.text = before ?? ""
        return [op]
    }
    guard let before = before else {
        // the change created the file: delete it again, provided nothing else was written to it since
        var op = Op(kind: .deleteFile, path: path); op.old = after
        return [op]
    }
    let a = before.components(separatedBy: "\n"), b = after.components(separatedBy: "\n")
    // the smallest context that makes a region's new text unique in the file
    func choose(_ h: (a: Range<Int>, b: Range<Int>)) -> (k: Int, old: [String], new: [String]) {
        // an empty side needs a line of context: replacing lines with nothing would leave a blank line
        var k = h.b.isEmpty || h.a.isEmpty ? 1 : 0
        while true {
            let pre = Array(b[max(0, h.b.lowerBound - k)..<h.b.lowerBound])
            let post = Array(b[h.b.upperBound..<min(b.count, h.b.upperBound + k)])
            let old = pre + Array(b[h.b]) + post
            let whole = h.b.lowerBound - k <= 0 && h.b.upperBound + k >= b.count
            if whole || (old.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) && occurrences(old, in: b) == 1) {
                return (k, old, pre + Array(a[h.a]) + post)
            }
            k += 1
        }
    }
    var hunks = lineHunks(a, b)
    var picked = hunks.map(choose)
    // regions whose context reaches into a neighbour are merged, so each replace still finds its text
    var i = 0
    while i + 1 < hunks.count {
        let x = hunks[i], y = hunks[i + 1]
        if x.b.upperBound + picked[i].k > y.b.lowerBound || y.b.lowerBound - picked[i + 1].k < x.b.upperBound {
            let m = (x.a.lowerBound..<y.a.upperBound, x.b.lowerBound..<y.b.upperBound)
            hunks.replaceSubrange(i...i + 1, with: [m])
            picked.replaceSubrange(i...i + 1, with: [choose(m)])
            i = max(0, i - 1)
        } else { i += 1 }
    }
    return picked.map { c in
        var op = Op(kind: .replace, path: path)
        op.old = c.old.joined(separator: "\n")
        op.text = c.new.joined(separator: "\n")
        return op
    }
}

/// the regions a record changed, for showing what it did
public func changeHunks(_ r: ChangeRecord) -> [ChangeHunk] {
    r.undo.compactMap { op in
        switch op.kind {
        case .replace:
            // op.old is what the change wrote, op.text what was there before
            let now = (op.old ?? "").components(separatedBy: "\n"), was = (op.text ?? "").components(separatedBy: "\n")
            var p = 0
            while p < now.count, p < was.count, now[p] == was[p] { p += 1 }
            var s = 0
            while s < now.count - p, s < was.count - p, now[now.count - 1 - s] == was[was.count - 1 - s] { s += 1 }
            return ChangeHunk(path: op.path, context: (Array(now[0..<p]), Array(now[(now.count - s)...])),
                              removed: Array(was[p..<(was.count - s)]), added: Array(now[p..<(now.count - s)]))
        case .deleteFile:
            return ChangeHunk(path: op.path, context: ([], []), removed: [], added: (op.old ?? "").components(separatedBy: "\n"))
        case .write:
            return ChangeHunk(path: op.path, context: ([], []), removed: (op.text ?? "").components(separatedBy: "\n"), added: [])
        default:
            return nil
        }
    }
}

public enum UndoProblem: Error, Equatable {
    /// a region the change wrote is not in the file any more (edited or removed since)
    case changedSince(path: String)
}

/// The ops to take `r` back, checked against the files as they are now (`current(path)`, nil when the
/// file does not exist). Fails when something the change wrote has been edited since.
public func undoOps(_ r: ChangeRecord, current: (String) -> String?) -> Result<[Op], UndoProblem> {
    var texts: [String: String?] = [:]
    func text(_ p: String) -> String? {
        if let t = texts[p] { return t }
        let t = current(p); texts[p] = t; return t
    }
    var out: [Op] = []
    for var op in r.undo {
        switch op.kind {
        case .deleteFile:
            guard let cur = text(op.path) else { continue }   // already gone
            if cur.trimmingCharacters(in: .whitespacesAndNewlines) == (op.old ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
                op.old = nil
                out.append(op)
                texts[op.path] = .some(nil)
            } else {
                // more was written to the file since: take out only what this change added
                var t = cur
                for o in revertOps(path: op.path, before: "", after: op.old ?? "") {
                    guard let n = applyRemove(t, o) else { return .failure(.changedSince(path: op.path)) }
                    t = n; out.append(o)
                }
                texts[op.path] = t
            }
        case .write:
            if text(op.path) != nil { return .failure(.changedSince(path: op.path)) }
            out.append(op)
            texts[op.path] = op.text
        case .replace:
            guard let cur = text(op.path), let n = applyRemove(cur, op) else { return .failure(.changedSince(path: op.path)) }
            texts[op.path] = n
            out.append(op)
        default:
            continue
        }
    }
    for i in out.indices { out[i].id = UUID() }
    return .success(out)
}
