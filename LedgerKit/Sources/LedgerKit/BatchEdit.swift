import Foundation

/// 批量编辑: one change made to the text of several transactions at once, on the phone and the Mac alike
public enum BatchEdit: Equatable, Sendable {
    /// a posting's account changed: exactly that account, not its sub-accounts
    case account(from: String, to: String)
    /// `#tag` added on the header
    case tag(String)
    /// `^link` added on the header
    case link(String)

    /// a word typed for a tag or a link as it is written: no leading # or ^, spaces as -
    public static func word(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#^")).replacingOccurrences(of: " ", with: "-")
    }

    /// whether there is enough to apply it
    public var ready: Bool {
        switch self {
        case .account(let from, let to): return !from.isEmpty && isAccountName(to) && from != to
        case .tag(let word), .link(let word): return !word.isEmpty
        }
    }

    /// how many of `entries` it would change
    public func affected(_ entries: [Entry]) -> Int {
        switch self {
        case .account(let from, _): return entries.filter { t in t.postings.contains { $0.account == from } }.count
        case .tag(let word): return entries.filter { !$0.tags.contains(word) }.count
        case .link(let word): return entries.filter { !$0.links.contains(word) }.count
        }
    }

    /// a transaction's text with the change made; nil when there is nothing to change in it
    public func applied(to block: String) -> String? {
        switch self {
        case .account(let from, let to):
            return accountReplaced(in: block, from: from, to: to)
        case .tag(let word), .link(let word):
            // on the header, before a trailing comment
            let new = headerWordAdd(block, (isTag ? "#" : "^") + word)
            return new == block ? nil : new
        }
    }

    private var isTag: Bool { if case .tag = self { return true } else { return false } }
}

/// a transaction's text with one posting's account changed (exactly that account, not its sub-accounts); nil when
/// it has no such posting
public func accountReplaced(in block: String, from: String, to: String) -> String? {
    var lines = block.components(separatedBy: "\n")
    var changed = false
    for i in lines.indices.dropFirst() {
        let l = lines[i]
        let body = l.trimmingCharacters(in: .whitespaces)
        let flagged = body.hasPrefix("! ") || body.hasPrefix("* ")
        let name = (flagged ? String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces) : body).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        if name == from, let r = l.range(of: from) {
            lines[i] = l.replacingCharacters(in: r, with: to)
            changed = true
        }
    }
    return changed ? alignText(lines.joined(separator: "\n")) : nil
}

/// One replace op per transaction `transform` changes (each found by its own line, not an identical copy elsewhere),
/// bottom up in each file; the first carries `label` and the rest are silent, so the change reads as one step.
/// `lines` gives a file's text, split into lines; a transaction whose file can't be read is left out.
public func rewriteOps(_ entries: [Entry], label: String, lines: (String) -> [String]?, transform: (String) -> String?) -> [Op] {
    var ops: [Op] = []
    var cache: [String: [String]] = [:]
    for t in entries.sorted(by: { $0.date < $1.date }) {
        if cache[t.file] == nil { cache[t.file] = lines(t.file) }
        guard let text = cache[t.file], t.endLine < text.count else { continue }
        let old = text[t.startLine...t.endLine].joined(separator: "\n")
        guard let new = transform(old) else { continue }
        var op = Op(kind: .replace, path: t.file)
        op.old = old
        op.text = new
        op.date = t.date
        op.anchorLine = t.line
        op.summary = [t.payee, t.narration].filter { !$0.isEmpty }.joined(separator: " ")
        ops.append(op)
    }
    ops = bottomUp(ops)
    for i in ops.indices {
        ops[i].label = i == 0 ? label : nil
        ops[i].silent = i == 0 ? nil : true
    }
    return ops
}

/// A batch edit written into a ledger folder (the Mac), as one step
public func prepareFolderBatch(_ entries: [Entry], _ edit: BatchEdit, label: String, folder: URL) -> Result<FolderSave, FolderSaveError> {
    prepareFolderOps(folder: folder) { _, _, file in
        let ops = rewriteOps(entries, label: label, lines: { file($0)?.components(separatedBy: "\n") }, transform: edit.applied(to:))
        return ops.isEmpty ? .failure(FolderSaveError(message: tr("没有需要修改的交易", "Nothing to change"))) : .success(ops)
    }
}
