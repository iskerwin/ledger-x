import Foundation

// MARK: - writing (matches the user's formatting: number ends at col 59)

public let NUM_END = 59

@inline(__always) func jsLen(_ s: String) -> Int { s.utf16.count }

public func numText(_ n: Double) -> String {
    let r = roundTo(n, 10)
    // JS String() switches to exponent notation below 1e-6 ("1e-7", "1.5e-7")
    var s = jsNumberString(r)
    if r != 0 && abs(r) < 1e-6 {
        let e = "\(r)"   // Swift: "1e-07" / "1.5e-07"
        if let k = e.firstIndex(of: "e") {
            let exp = Int(e[e.index(after: k)...]) ?? 0
            s = String(e[..<k]) + "e" + String(exp)
        }
    }
    let d = s.split(separator: ".").count > 1 ? s.split(separator: ".")[1].count : 0
    return toFixed(n, max(2, min(d, 10)))
}

/// units: nil (left blank), or already-formatted text (a number or an expression)
public func fmtPostingLine(_ account: String, _ units: String?, _ currency: String?, _ suffix: String = "", flag: String? = nil) -> String {
    let left = "  " + (flag.map { $0 + " " } ?? "") + account
    guard let ns = units, !ns.isEmpty else {
        return left + (currency.map { $0.isEmpty ? "" : "  " + $0 } ?? "") + (suffix.isEmpty ? "" : " " + suffix)
    }
    let pad = max(2, NUM_END - jsLen(left) - jsLen(ns))
    return left + String(repeating: " ", count: pad) + ns + " " + (currency ?? "") + (suffix.isEmpty ? "" : " " + suffix)
}

/// only quotes are escaped: Beancount reads every other backslash as it is
public func quoted(_ s: String?) -> String {
    "\"" + (s ?? "").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private let plainMetaRE = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2}|TRUE|FALSE|-?[\d.]+(\s+[A-Z][A-Z0-9'._-]*)?)$"#)

/// a metadata line; `v` is plain text (quoted unless it reads as a number, date, amount or TRUE / FALSE), or
/// already a quoted string ("\"4200…\"", for text that only looks like a number and must stay text)
func metaLine(_ indent: String, _ k: String, _ v: String) -> String {
    if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { return "\(indent)\(k): \(v)" }
    let plain = plainMetaRE.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)) != nil
    return "\(indent)\(k): \(plain ? v : quoted(v))"
}

public struct TxPosting {
    public var account: String
    public var units: String?
    public var currency: String?
    public var flag: String?
    public var cost: String?      // "335.5 USD" or "{...}"
    public var price: String?     // "@ 1.19 HKD" or "1.19 HKD"
    public var priceTotal: Double?
    public var priceCcy: String?
    public var meta: [(String, String)] = []
    public var suffix: String?    // appended after the posting (per-unit @ for fx spends)

    public init(account: String, units: String? = nil, currency: String? = nil, flag: String? = nil, cost: String? = nil, price: String? = nil) {
        self.account = account; self.units = units; self.currency = currency; self.flag = flag; self.cost = cost; self.price = price
    }
    public init(account: String, amount: Double, currency: String) {
        self.account = account; self.units = numText(amount); self.currency = currency
    }
}

public struct TxDraft {
    public var date: String
    public var flag: String = "*"
    public var payee: String = ""
    public var narration: String = ""
    public var hasPayee: Bool = true
    public var tags: [String] = []
    public var links: [String] = []
    public var meta: [(String, String)] = []
    public var postings: [TxPosting] = []
    public init(date: String) { self.date = date }
}

public func formatTxn(_ tx: TxDraft) -> String {
    var head = [tx.date, tx.flag.isEmpty ? "*" : tx.flag]
    if !tx.payee.isEmpty || tx.hasPayee { head.append(quoted(tx.payee)) }
    head.append(quoted(tx.narration))
    for t in tx.tags { head.append("#" + t) }
    for l in tx.links { head.append("^" + l) }
    var lines = [head.joined(separator: " ")]
    for (k, v) in tx.meta { lines.append(metaLine("  ", k, v)) }
    for p in orderedPostings(tx.postings) {
        var sfx: [String] = []
        if let c = p.cost, !c.isEmpty { sfx.append(c.hasPrefix("{") ? c : "{\(c)}") }
        if let pr = p.price, !pr.isEmpty { sfx.append(pr.hasPrefix("@") ? pr : "@ \(pr)") }
        // written with the places it has (12.345 KWD stays 12.345), at least two, as an amount is
        if let pt = p.priceTotal { sfx.append("@@ \(numText(pt)) \(p.priceCcy ?? "")") }
        if let s = p.suffix, !s.isEmpty { sfx.append(s) }
        lines.append(fmtPostingLine(p.account, p.units, p.currency, sfx.joined(separator: " "), flag: p.flag))
        for (k, v) in p.meta { lines.append(metaLine("    ", k, v)) }
    }
    return lines.joined(separator: "\n")
}

// MARK: - posting order

/// The order every transaction is written in: Expenses / Income / Equity lines first (as given), then the
/// Assets / Liabilities lines that receive money (amount ≥ 0), then those that pay (amount < 0). A posting left
/// without an amount takes the sign Beancount will fill it with. When a sign can't be told (an expression, two
/// blank amounts, mixed currencies around a blank one) the postings are left as given.
public func orderedPostings(_ ps: [TxPosting]) -> [TxPosting] {
    guard ps.count > 1 else { return ps }
    func isBalanceSheet(_ a: String) -> Bool { a.hasPrefix("Assets:") || a.hasPrefix("Liabilities:") }
    var signs: [Double?] = ps.map { postingNumber($0.units) }
    let blank = ps.indices.filter { (ps[$0].units ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    if blank.count > 1 { return ps }
    if let b = blank.first {
        if isBalanceSheet(ps[b].account) {
            guard let w = weightOfOthers(ps, except: b) else { return ps }
            signs[b] = -w
        } else {
            signs[b] = 0
        }
    }
    for i in ps.indices where isBalanceSheet(ps[i].account) && signs[i] == nil { return ps }
    let cats = ps.indices.filter { !isBalanceSheet(ps[$0].account) }
    let recv = ps.indices.filter { isBalanceSheet(ps[$0].account) && signs[$0]! >= 0 }
    let pay = ps.indices.filter { isBalanceSheet(ps[$0].account) && signs[$0]! < 0 }
    return (cats + recv + pay).map { ps[$0] }
}

/// a plain number ("-1,234.50"), or nil for a blank or an expression
private func postingNumber(_ s: String?) -> Double? {
    guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
    let c = t.replacingOccurrences(of: ",", with: "")
    guard c.range(of: #"^[+-]?(\d+\.?\d*|\.\d+)$"#, options: .regularExpression) != nil else { return nil }
    return Double(c)
}

/// "335.5 USD", "{335.5 USD}", "{{671 USD}}", "@ 1.19 HKD", "@@ 20.00 CNY" → (number, currency)
private func amountIn(_ s: String) -> (Double, String)? {
    let parts = s.split(whereSeparator: { "{}@ ".contains($0) }).map(String.init)
    guard parts.count == 2, let n = postingNumber(parts[0]) else { return nil }
    return (n, parts[1])
}

/// what the other postings weigh together (at cost or price), when they all weigh in one currency
private func weightOfOthers(_ ps: [TxPosting], except b: Int) -> Double? {
    var total = 0.0
    var curs = Set<String>()
    for (i, p) in ps.enumerated() where i != b {
        guard let n = postingNumber(p.units) else { return nil }
        let sign: Double = n < 0 ? -1 : 1
        let cost = p.cost?.trimmingCharacters(in: .whitespaces) ?? ""
        // a price is either `price` ("1.19 HKD" / "@ 1.19 HKD" / "@@ …") or an @ written as the suffix
        let given = p.price?.trimmingCharacters(in: .whitespaces) ?? ""
        let tail = p.suffix?.trimmingCharacters(in: .whitespaces) ?? ""
        let price = !given.isEmpty ? given : (tail.hasPrefix("@") ? tail : "")
        if !cost.isEmpty {
            guard let (v, c) = amountIn(cost) else { return nil }
            total += cost.hasPrefix("{{") ? sign * abs(v) : n * v
            curs.insert(c)
        } else if let pt = p.priceTotal {
            total += sign * abs(pt)
            curs.insert(p.priceCcy ?? "")
        } else if !price.isEmpty {
            guard let (v, c) = amountIn(price) else { return nil }
            total += price.hasPrefix("@@") ? sign * abs(v) : n * v
            curs.insert(c)
        } else {
            total += n
            curs.insert(p.currency ?? "")
        }
    }
    return curs.count == 1 ? total : nil
}

private func leadingDate(_ l: String) -> String? {
    let s = scalars(l)
    guard s.count >= 11, let d = dateAt(s, 0), s[4] == "-", s[7] == "-", isWS(s[10]) else { return nil }
    return d
}
private func startsWithYear(_ l: String) -> Bool {
    let s = scalars(l)
    return s.count >= 5 && isDigit(s[0]) && isDigit(s[1]) && isDigit(s[2]) && isDigit(s[3]) && s[4] == "-"
}
private func startsIndented(_ l: String) -> Bool { l.hasPrefix(" ") || l.hasPrefix("\t") }
private func blank(_ l: String) -> Bool { l.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

/// JS `text.replace(/\s+$/, '')`
func trimTrailing(_ text: String) -> String {
    var s = Substring(text)
    while let last = s.unicodeScalars.last, isWS(last) { s = s.dropLast() }
    return String(s)
}

/// insert a formatted entry into a file, keeping date order
/// (after the last dated entry whose date <= new date)
public func insertEntry(_ text: String, _ entryText: String, _ date: String) -> String {
    let lines = trimTrailing(text).components(separatedBy: "\n")
    if lines.count == 1 && lines[0].isEmpty { return entryText + "\n" }
    var blocks: [(i: Int, date: String)] = []
    for (i, l) in lines.enumerated() { if let d = leadingDate(l) { blocks.append((i, d)) } }
    var lastLE = -1
    for (b, blk) in blocks.enumerated() where blk.date <= date { lastLE = b }
    let entryLines = entryText.components(separatedBy: "\n")
    var insertAt: Int
    if lastLE == -1 {
        if let first = blocks.first {
            insertAt = first.i
            return (Array(lines[..<insertAt]) + entryLines + [""] + Array(lines[insertAt...])).joined(separator: "\n") + "\n"
        }
        insertAt = lines.count
    } else {
        var j = blocks[lastLE].i + 1
        while j < lines.count && !blank(lines[j]) && !startsWithYear(lines[j]) && startsIndented(lines[j]) { j += 1 }
        insertAt = j
    }
    let before = Array(lines[..<insertAt])
    var after = Array(lines[insertAt...])
    while let f = after.first, blank(f) { after.removeFirst() }
    // single-line directives in a run of single-line directives (balance/price/open) stay compact
    let single = !entryText.contains("\n")
    let prevSingle = !before.isEmpty && startsWithYear(before[before.count - 1])
    let nextSingle = !after.isEmpty && startsWithYear(after[0]) && !(after.count > 1 && startsIndented(after[1]))
    let sepBefore: [String] = single && prevSingle ? [] : [""]
    let sepAfter: [String] = after.isEmpty ? [] : (single && nextSingle ? [] : [""])
    return (before + sepBefore + entryLines + sepAfter + after).joined(separator: "\n") + "\n"
}

private let NUMP = #"-?[0-9][0-9,]*(?:\.[0-9]+)?"#
private let CURP = #"[A-Z][A-Z0-9'._\-]*"#
private let postRE = try! NSRegularExpression(pattern: #"^(\s+)((?:[!*&#?%PSTCURM]\s+)?[A-Z\p{Lu}][^\s]*)\s+("# + NUMP + #")\s+("# + CURP + #")(\s.*)?$"#)
private let dirRE = try! NSRegularExpression(pattern: #"^([0-9]{4}-[0-9]{2}-[0-9]{2}\s+(?:balance\s+\S+|price\s+\S+))\s+("# + NUMP + #")(\s*~\s*"# + NUMP + #")?\s+("# + CURP + #")(\s.*)?$"#)
private let flagPrefixRE = try! NSRegularExpression(pattern: #"^[!*&#?%PSTCURM]\s+"#)

private func group(_ m: NSTextCheckingResult, _ k: Int, _ s: String) -> String? {
    let r = m.range(at: k)
    guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
    return String(s[rr])
}
private func replaceFirst(_ re: NSRegularExpression, _ s: String, _ with: String) -> String {
    re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: with)
}
private let firstWS = try! NSRegularExpression(pattern: #"\s+"#)
private func collapseFirstWS(_ s: String) -> String {
    guard let m = firstWS.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return s }
    return (s as NSString).replacingCharacters(in: m.range, with: " ")
}

/// Re-align plain-number amounts to the ledger's column (postings, balance, price lines).
/// Never changes content: expressions, comments and anything unrecognised are left alone.
public func alignText(_ text: String) -> String {
    text.components(separatedBy: "\n").map { l -> String in
        let full = NSRange(location: 0, length: (l as NSString).length)
        if let m = postRE.firstMatch(in: l, range: full), let acctPart = group(m, 2, l) {
            let bare = replaceFirst(flagPrefixRE, acctPart, "")
            if accountLength(scalars(bare), 0) > 0 {
                let num = group(m, 3, l)!, cur = group(m, 4, l)!
                let rest = group(m, 5, l)
                let left = "  " + collapseFirstWS(acctPart)
                let pad = max(2, NUM_END - jsLen(left) - jsLen(num))
                return left + String(repeating: " ", count: pad) + num + " " + cur + (rest != nil ? " " + rest!.trimmingCharacters(in: .whitespaces) : "")
            }
        }
        if let m = dirRE.firstMatch(in: l, range: full) {
            let left = group(m, 1, l)!.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            let num = group(m, 2, l)!
            let tol = group(m, 3, l)
            let cur = group(m, 4, l)!
            let rest = group(m, 5, l)
            let pad = max(1, NUM_END - jsLen(left) - jsLen(num))
            let tolText = tol.map { " ~ " + $0.replacingOccurrences(of: #"[\s~]"#, with: "", options: .regularExpression) } ?? ""
            return left + String(repeating: " ", count: pad) + num + tolText + " " + cur + (rest != nil ? " " + rest!.trimmingCharacters(in: .whitespaces) : "")
        }
        return l
    }.joined(separator: "\n")
}

// MARK: - edits applied to repo files (pending queue)

public struct Op: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable { case insert, remove, link, include, balance, deleteFile, replace, rename, renamePayee, write }
    public var id = UUID()
    public var kind: Kind
    public var path: String
    public var date: String?
    public var text: String?
    public var old: String?
    public var line: String?          // include line / balance line
    public var headerLine: Int?
    public var header: String?
    public var link: String?
    public var add: String?
    public var account: String?
    public var currency: String?
    public var replace: Bool?
    public var label: String?
    public var summary: String?
    public var amountText: String?
    public var silent: Bool?
    public var failed: String?
    /// kept on this device only (the pre-commit check found a problem); never pushed until released
    public var held: String?
    /// ops kept together by one decision are released together
    public var heldGroup: UUID?
    /// held groups this change makes valid again: released and pushed together with it
    public var releases: [UUID]?
    /// an insert that is an entry moved by an edit (a new date): the text of the entry it takes the place of
    public var moves: String?
    /// 1-based first line of the entry a remove or replace must change when the same text occurs more than once.
    /// Absent on edits queued before this was recorded: those still change the first copy.
    public var anchorLine: Int?

    public init(kind: Kind, path: String) { self.kind = kind; self.path = path }
}

public struct ConflictError: Error, LocalizedError {
    public let label: String
    public var errorDescription: String? { tr("要修改的交易在 GitHub 上已经变了：\(label)。请在设置里删除这一项后重新编辑。", "The entry being changed was modified on GitHub: \(label). Remove this item in Settings and edit again.") }
}

public func applyOps(_ text0: String, path: String, ops: [Op], strict: Bool = false) throws -> String {
    var text = text0
    for op in ops where op.path == path && op.failed == nil {
        switch op.kind {
        case .insert: text = insertEntry(text, op.text ?? "", op.date ?? "")
        case .link: text = addLinkToHeader(text, op) ?? text
        case .include: if let l = op.line, !text.contains(l) { text = addInclude(text, l) }
        case .remove:
            if let r = applyRemove(text, op) { text = r }
            else if strict { throw ConflictError(label: op.label ?? "") }
        case .balance: text = insertBalance(text, op)
        case .deleteFile: break
        case .replace:
            if let r = applyRemove(text, op) { text = r }
            else if strict { throw ConflictError(label: op.label ?? "") }
        case .rename: text = renameAccount(text, from: op.old ?? "", to: op.text ?? "")
        case .renamePayee: text = renamePayee(text, from: op.old ?? "", to: op.text ?? "")
        case .write: text = op.text ?? ""
        }
    }
    return text
}

private func trimEndStr(_ s: Substring) -> String {
    var x = s
    while let last = x.unicodeScalars.last, isWS(last) { x = x.dropLast() }
    return String(x)
}

/// a remove op: a whole entry (`old`) or a single directive line (`line`, e.g. a balance assertion)
public func applyRemove(_ text: String, _ op: Op) -> String? {
    if op.kind == .replace { return replaceBlock(text, op.old ?? "", op.text ?? "", anchorLine: op.anchorLine) }
    if let l = op.line { return removeLine(text, l) }
    return removeBlock(text, op.old ?? "", anchorLine: op.anchorLine)
}

/// remove the first line equal to `line` (ignoring trailing spaces), leaving blank lines alone
public func removeLine(_ text: String, _ line: String) -> String? {
    var lines = text.components(separatedBy: "\n")
    let want = trimEndStr(Substring(line))
    guard !want.isEmpty, let i = lines.firstIndex(where: { trimEndStr(Substring($0)) == want }) else { return nil }
    lines.remove(at: i)
    return lines.joined(separator: "\n")
}

/// where `old` occurs, line by line, ignoring trailing spaces
private func blockHits(_ lines: [String], _ ol: [String]) -> [Int] {
    guard !ol.isEmpty, ol.count <= lines.count else { return [] }
    var hits: [Int] = []
    var i = 0
    while i + ol.count <= lines.count {
        var ok = true
        for k in 0..<ol.count where trimEndStr(Substring(lines[i + k])) != ol[k] { ok = false; break }
        if ok { hits.append(i) }
        i += 1
    }
    return hits
}

/// `anchorLine` is the 1-based first line. Several copies: only the one that still starts there.
/// One copy: that copy, even if its line has moved. No anchor: the first copy, as edits queued earlier did.
private func pickBlock(_ hits: [Int], anchorLine: Int?) -> Int? {
    if let anchorLine {
        let i = anchorLine - 1
        if hits.contains(i) { return i }
        return hits.count == 1 ? hits[0] : nil
    }
    return hits.first
}

/// replace an entry (matched line by line, ignoring trailing spaces) with new text, in place
public func replaceBlock(_ text: String, _ old: String, _ new: String, anchorLine: Int? = nil) -> String? {
    var lines = text.components(separatedBy: "\n")
    let ol = old.components(separatedBy: "\n").map { trimEndStr(Substring($0)) }
    guard !ol.isEmpty, !old.isEmpty, let i = pickBlock(blockHits(lines, ol), anchorLine: anchorLine) else { return nil }
    lines.replaceSubrange(i..<i + ol.count, with: new.components(separatedBy: "\n"))
    return lines.joined(separator: "\n")
}

/// Replacing `e` with `text`, or removing it when `text` is nil: anchored to its first line, so an identical copy
/// elsewhere in the file (two of the same coffee on one day) is left alone.
public func entryOp(_ e: Entry, text: String?) -> Op {
    var op = Op(kind: text == nil ? .remove : .replace, path: e.file)
    op.old = e.src
    op.text = text
    op.date = e.date
    op.anchorLine = e.line
    return op
}

/// Edits of one file made against the same text, ordered from the bottom up: one that adds or drops lines then
/// leaves the lines the later ones are anchored to where they were. Other files keep their order.
public func bottomUp(_ ops: [Op]) -> [Op] {
    ops.enumerated().sorted { a, b in
        guard a.element.path == b.element.path else { return a.offset < b.offset }
        let x = a.element.anchorLine ?? 0, y = b.element.anchorLine ?? 0
        return x != y ? x > y : a.offset < b.offset
    }.map(\.element)
}

private func accountRegex(_ name: String) -> NSRegularExpression? {
    try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}:\\-])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}\\-])")
}

/// rename an account (and its sub-accounts) everywhere in a file
public func renameAccount(_ text: String, from: String, to: String) -> String {
    guard !from.isEmpty, !to.isEmpty, from != to, let re = accountRegex(from) else { return text }
    return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                       withTemplate: NSRegularExpression.escapedTemplate(for: to))
}

// MARK: - payees

/// a transaction header with a payee: `2026-10-01 * "payee" "narration"`; group 1 is the payee's quoted text
private let payeeHeaderRE = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}[ \t]+(?:\*|!|txn|[A-Z?#%&])[ \t]+("(?:[^"\\]|\\.)*")[ \t]+"(?:[^"\\]|\\.)*""#, options: [.anchorsMatchLines])
/// `payee: "…"` metadata (subscriptions name the payee their charges come from this way)
private let payeeMetaRE = try! NSRegularExpression(pattern: #"^([ \t]+payee:[ \t]*)("(?:[^"\\]|\\.)*")"#, options: [.anchorsMatchLines])

/// the text of a quoted Beancount string ("a \"b\"" → a "b")
func unquote(_ q: String) -> String {
    var s = q
    if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 { s = String(s.dropFirst().dropLast()) }
    var out = "", esc = false
    for ch in s {
        if esc { out.append(ch); esc = false } else if ch == "\\" { esc = true } else { out.append(ch) }
    }
    return out
}

/// ranges of the quoted payees equal to `name`: on transaction headers, and in `payee:` metadata
private func payeeRanges(_ text: String, _ name: String) -> [NSRange] {
    let ns = text as NSString, all = NSRange(location: 0, length: ns.length)
    var out: [NSRange] = []
    for re in [payeeHeaderRE, payeeMetaRE] {
        let g = re === payeeHeaderRE ? 1 : 2
        for m in re.matches(in: text, range: all) where unquote(ns.substring(with: m.range(at: g))) == name {
            out.append(m.range(at: g))
        }
    }
    return out.sorted { $0.location > $1.location }
}

/// every transaction paid to / received from `from` (and subscriptions naming it) now names `to`; nothing else
/// on the lines changes
public func renamePayee(_ text: String, from: String, to: String) -> String {
    guard !from.isEmpty, !to.trimmingCharacters(in: .whitespaces).isEmpty, from != to else { return text }
    let m = NSMutableString(string: text)
    for r in payeeRanges(text, from) { m.replaceCharacters(in: r, with: quoted(to)) }
    return m as String
}

/// how many headers and `payee:` lines name `name` in a file
public func countPayee(_ text: String, _ name: String) -> Int { payeeRanges(text, name).count }

/// how many times an account (or its sub-accounts) appears in a file
public func countAccount(_ text: String, _ name: String) -> Int {
    guard let re = accountRegex(name) else { return 0 }
    return re.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
}

public func removeBlock(_ text: String, _ old: String, anchorLine: Int? = nil) -> String? {
    var lines = text.components(separatedBy: "\n")
    let ol = old.components(separatedBy: "\n").map { trimEndStr(Substring($0)) }
    guard let i = pickBlock(blockHits(lines, ol), anchorLine: anchorLine) else { return nil }
    var n = ol.count
    var start = i
    if i + n < lines.count && blank(lines[i + n]) { n += 1 }
    else if i > 0 && blank(lines[i - 1]) { start -= 1; n += 1 }
    lines.removeSubrange(start..<start + n)
    return lines.joined(separator: "\n")
}

public func balanceLine(_ date: String, _ account: String, _ amount: Double, _ currency: String) -> String {
    let left = "\(date) balance \(account)"
    let ns = numText(amount)
    return left + String(repeating: " ", count: max(1, NUM_END - jsLen(left) - jsLen(ns))) + ns + " " + currency
}

public func insertBalance(_ text: String, _ op: Op) -> String {
    var lines = trimTrailing(text).components(separatedBy: "\n")
    let account = op.account ?? "", date = op.date ?? "", line = op.line ?? ""
    let acc = NSRegularExpression.escapedPattern(for: account)
    if op.replace == true, let cur = op.currency {
        let same = try! NSRegularExpression(pattern: "^\(NSRegularExpression.escapedPattern(for: date))\\s+balance\\s+\(acc)\\s[^;]*?\\s\(NSRegularExpression.escapedPattern(for: cur))(\\s|;|$)")
        if let i = lines.firstIndex(where: { same.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }) {
            lines[i] = line
            return lines.joined(separator: "\n") + "\n"
        }
    }
    let re = try! NSRegularExpression(pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}\\s+balance\\s+\(acc)\\s")
    let match = { (l: String) in re.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) != nil }
    var last = -1
    for (i, l) in lines.enumerated() where match(l) && String(l.prefix(10)) <= date { last = i }
    if last < 0 { for (i, l) in lines.enumerated() where match(l) { last = i } }
    if last >= 0 { lines.insert(line, at: last + 1) } else { lines.append(""); lines.append(line) }
    return lines.joined(separator: "\n") + "\n"
}

public func addLinkToHeader(_ text: String, _ op: Op) -> String? {
    var lines = text.components(separatedBy: "\n")
    guard let header = op.header else { return nil }
    var idx = -1
    if let ln = op.headerLine, ln - 1 >= 0, ln - 1 < lines.count, lines[ln - 1] == header { idx = ln - 1 }
    else if let k = lines.firstIndex(of: header) { idx = k }
    if idx < 0 { return nil }
    let add = op.add ?? " ^" + (op.link ?? "")
    let lastWord = add.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").last ?? ""
    // whole words only: ^trip is not already there just because ^trip-2026 is
    if lines[idx].split(whereSeparator: { $0 == " " || $0 == "\t" }).contains(where: { String($0) == lastWord }) { return text }
    lines[idx] = trimTrailing(lines[idx]) + add
    return lines.joined(separator: "\n")
}

public func addInclude(_ text: String, _ line: String) -> String {
    var lines = text.components(separatedBy: "\n")
    var last = -1
    // put it after the include lines for the same folder (e.g. the other years)
    let target = line.components(separatedBy: "\"").dropFirst().first ?? ""
    let dir = target.range(of: "/", options: .backwards).map { String(target[..<$0.upperBound]) } ?? ""
    for (i, l) in lines.enumerated() where l.hasPrefix("include") {
        let p = l.components(separatedBy: "\"").dropFirst().first ?? ""
        let pdir = p.range(of: "/", options: .backwards).map { String(p[..<$0.upperBound]) } ?? ""
        if pdir == dir { last = i }
    }
    if last < 0 {
        return trimTrailing(text) + "\n" + line + "\n"
    }
    lines.insert(line, at: last + 1)
    return lines.joined(separator: "\n")
}

/// Put entries of one file in a new order, in the stretch of the file they take up.
/// `ranges` are their lines (start…end, inclusive) in file order; `order[i]` is the entry going to the i-th place.
/// Whatever lies between them (blank lines, a balance assertion, a comment) stays where it is.
/// Returns that stretch before and after, for a replace op; nil when the ranges don't fit the text.
public func reorderBlocks(_ text: String, ranges: [(start: Int, end: Int)], order: [Int]) -> (old: String, new: String)? {
    let lines = text.components(separatedBy: "\n")
    guard ranges.count > 1, order.count == ranges.count, Set(order) == Set(ranges.indices),
          let first = ranges.first, let last = ranges.last, first.start >= 0, last.end < lines.count else { return nil }
    for k in 1..<ranges.count where ranges[k].start <= ranges[k - 1].end { return nil }
    let blocks = ranges.map { Array(lines[$0.start...$0.end]) }
    let gaps = (0..<ranges.count - 1).map { k in Array(lines[(ranges[k].end + 1)..<ranges[k + 1].start]) }
    var out: [String] = []
    for (i, j) in order.enumerated() {
        out += blocks[j]
        if i < gaps.count { out += gaps[i] }
    }
    let old = lines[first.start...last.end].joined(separator: "\n")
    return (old, out.joined(separator: "\n"))
}
