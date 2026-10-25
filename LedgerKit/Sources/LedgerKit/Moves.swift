import Foundation

// A page showing a transaction knows it by its date and text. When a change rewrites the transaction (a link
// added, a payee or account renamed, the entry edited or moved to another day), the page follows it to its new
// text through what `movedEntries` works out here — with the same functions that write the files.

/// a transaction's text compared without trailing spaces or blank lines around it. Without a regular expression:
/// pages finding a transaction and the moves below run it over every transaction of the ledger.
public func normEntryText(_ s: String) -> String {
    var out = String()
    out.reserveCapacity(s.utf8.count)
    for (i, line) in s.components(separatedBy: "\n").enumerated() {
        var scalars = line.unicodeScalars[...]
        while let c = scalars.last, c.properties.isWhitespace { scalars = scalars.dropLast() }
        if i > 0 { out.unicodeScalars.append("\n") }
        out.unicodeScalars.append(contentsOf: scalars)
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// a transaction as a page remembers it: its date and text
public func txnKey(_ t: Entry) -> String { t.date + "\u{1}" + t.src }

/// Identity of a row in one list. `txnKey` does not change when the ledger is rebuilt and ids are
/// reassigned. A second copy of the same text (two identical top-ups) gets a suffix so the list's
/// ids stay unique; the suffix is that copy's place among the rows handed in, which are one day's.
public func txnRowID(_ t: Entry, among ts: [Entry]) -> String {
    let key = txnKey(t)
    var seen = 0
    var index = 0
    for o in ts where txnKey(o) == key {
        if o === t { index = seen }
        seen += 1
    }
    guard seen > 1 else { return key }
    return key + "\u{2}" + String(index)
}

/// Finds the transaction a page shows by where it was and its key (`txnKey`), following it through `moves` (old
/// key → new key, the old one as `normEntryText`) when a change rewrote it. Made once per loaded ledger: a page
/// redrawn many times while a change is saved looks it up in a table instead of comparing every transaction's text.
public final class TxnLookup {
    public let ledger: Ledger
    private let exact: [String: Int]
    /// only needed once something moved
    private lazy var normalised: [String: Int] = {
        var m: [String: Int] = [:]
        for (i, t) in ledger.txns.enumerated() where m[normEntryText(txnKey(t))] == nil { m[normEntryText(txnKey(t))] = i }
        return m
    }()

    public init(_ L: Ledger) {
        ledger = L
        var m: [String: Int] = [:]
        m.reserveCapacity(L.txns.count)
        for (i, t) in L.txns.enumerated() where m[txnKey(t)] == nil { m[txnKey(t)] = i }
        exact = m
    }

    public func find(id: Int, key: String, moves: [String: String]) -> Entry? {
        let txns = ledger.txns
        if id >= 0, id < txns.count, txnKey(txns[id]) == key { return txns[id] }
        if let i = exact[key] { return txns[i] }
        // edited in place (a link added or removed): follow it to its new text
        var k = key, hops = 0
        while let next = moves[normEntryText(k)], hops < 8 { k = next; hops += 1 }
        guard hops > 0 else { return nil }
        return normalised[normEntryText(k)].map { txns[$0] }
    }
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
    func find(_ text: String, line: Int?) -> Int? {
        let k = normEntryText(text)
        guard !k.isEmpty else { return nil }
        let hits = cur.indices.filter { normEntryText(cur[$0].src) == k }
        if let line, let i = hits.first(where: { cur[$0].line == line }) { return i }
        if hits.count == 1 { return hits[0] }
        // no remembered line: the first copy, as before. A line that no longer matches is not guessed.
        return line == nil ? hits.first : nil
    }
    for o in ops where o.failed == nil {
        switch o.kind {
        case .replace:
            guard let old = o.old, let new = o.text, let i = find(old, line: o.anchorLine) else { continue }
            cur[i].src = new
            if let d = o.date { cur[i].date = d }
        case .insert:
            // only an edit that moved the entry; a new one has nothing to follow
            guard let old = o.moves, let new = o.text, let i = find(old, line: o.anchorLine) else { continue }
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
