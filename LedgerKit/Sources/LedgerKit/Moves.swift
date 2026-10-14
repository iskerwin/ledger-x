import Foundation

// A page showing a transaction knows it by its date and text. When a change rewrites the transaction (a link
// added, a payee or account renamed, the entry edited or moved to another day), the page follows it to its new
// text through what `movedEntries` works out here — with the same functions that write the files.

/// a transaction's text compared without trailing spaces or blank lines around it
public func normEntryText(_ s: String) -> String {
    s.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// each transaction of `L` that `ops` change in place or move, as it was and as it will be
public struct MovedEntry: Equatable {
    public var oldDate: String
    public var old: String
    public var newDate: String
    public var new: String
}

public func movedEntries(_ ops: [Op], _ L: Ledger) -> [MovedEntry] {
    // the transactions the changes can touch, followed through the changes in order
    let paths = Set(ops.map { $0.path })
    struct Cur { let date0: String; let src0: String; var date: String; var src: String; var file: String; let line: Int }
    var cur = L.txns.filter { paths.contains($0.file) || ops.contains { $0.kind == .insert && $0.moves != nil } }
        .map { Cur(date0: $0.date, src0: $0.src, date: $0.date, src: $0.src, file: $0.file, line: $0.startLine + 1) }
    func find(_ text: String) -> Int? {
        let k = normEntryText(text)
        return k.isEmpty ? nil : cur.firstIndex { normEntryText($0.src) == k }
    }
    for o in ops where o.failed == nil {
        switch o.kind {
        case .replace:
            guard let old = o.old, let new = o.text, let i = find(old) else { continue }
            cur[i].src = new
            if let d = o.date { cur[i].date = d }
        case .insert:
            // only an edit that moved the entry; a new one has nothing to follow
            guard let old = o.moves, let new = o.text, let i = find(old) else { continue }
            cur[i].src = new; cur[i].file = o.path
            if let d = o.date { cur[i].date = d }
        case .link:
            guard let header = o.header else { continue }
            // the header on its line, as addLinkToHeader looks for it (else the first header like it)
            let h = normEntryText(header)
            func heads(_ c: Cur) -> Bool { c.file == o.path && normEntryText(c.src.components(separatedBy: "\n").first ?? "") == h }
            guard let i = cur.firstIndex(where: { heads($0) && $0.line == o.headerLine }) ?? cur.firstIndex(where: heads) else { continue }
            var one = o
            one.headerLine = 1
            one.header = cur[i].src.components(separatedBy: "\n").first
            if let new = addLinkToHeader(cur[i].src, one) { cur[i].src = new }
        case .rename, .renamePayee:
            guard let from = o.old, let to = o.text else { continue }
            for i in cur.indices where cur[i].file == o.path {
                cur[i].src = o.kind == .rename ? renameAccount(cur[i].src, from: from, to: to) : renamePayee(cur[i].src, from: from, to: to)
            }
        default: continue
        }
    }
    return cur.filter { normEntryText($0.src) != normEntryText($0.src0) || $0.date != $0.date0 }
        .map { MovedEntry(oldDate: $0.date0, old: $0.src0, newDate: $0.date, new: $0.src) }
}
