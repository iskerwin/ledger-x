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

public func quoted(_ s: String?) -> String {
    "\"" + (s ?? "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private let plainMetaRE = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2}|TRUE|FALSE|-?[\d.]+(\s+[A-Z][A-Z0-9'._-]*)?)$"#)

func metaLine(_ indent: String, _ k: String, _ v: String) -> String {
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
    for p in tx.postings {
        var sfx: [String] = []
        if let c = p.cost, !c.isEmpty { sfx.append(c.hasPrefix("{") ? c : "{\(c)}") }
        if let pr = p.price, !pr.isEmpty { sfx.append(pr.hasPrefix("@") ? pr : "@ \(pr)") }
        if let pt = p.priceTotal { sfx.append("@@ \(toFixed(pt, 2)) \(p.priceCcy ?? "")") }
        if let s = p.suffix, !s.isEmpty { sfx.append(s) }
        lines.append(fmtPostingLine(p.account, p.units, p.currency, sfx.joined(separator: " "), flag: p.flag))
        for (k, v) in p.meta { lines.append(metaLine("    ", k, v)) }
    }
    return lines.joined(separator: "\n")
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
    public enum Kind: String, Codable { case insert, remove, link, include, balance, deleteFile, replace, rename }
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
    if op.kind == .replace { return replaceBlock(text, op.old ?? "", op.text ?? "") }
    if let l = op.line { return removeLine(text, l) }
    return removeBlock(text, op.old ?? "")
}

/// remove the first line equal to `line` (ignoring trailing spaces), leaving blank lines alone
public func removeLine(_ text: String, _ line: String) -> String? {
    var lines = text.components(separatedBy: "\n")
    let want = trimEndStr(Substring(line))
    guard !want.isEmpty, let i = lines.firstIndex(where: { trimEndStr(Substring($0)) == want }) else { return nil }
    lines.remove(at: i)
    return lines.joined(separator: "\n")
}

/// replace an entry (matched line by line, ignoring trailing spaces) with new text, in place
public func replaceBlock(_ text: String, _ old: String, _ new: String) -> String? {
    var lines = text.components(separatedBy: "\n")
    let ol = old.components(separatedBy: "\n").map { trimEndStr(Substring($0)) }
    guard !ol.isEmpty, !old.isEmpty else { return nil }
    var i = 0
    while i + ol.count <= lines.count {
        var ok = true
        for k in 0..<ol.count where trimEndStr(Substring(lines[i + k])) != ol[k] { ok = false; break }
        if ok {
            lines.replaceSubrange(i..<i + ol.count, with: new.components(separatedBy: "\n"))
            return lines.joined(separator: "\n")
        }
        i += 1
    }
    return nil
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

/// how many times an account (or its sub-accounts) appears in a file
public func countAccount(_ text: String, _ name: String) -> Int {
    guard let re = accountRegex(name) else { return 0 }
    return re.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
}

public func removeBlock(_ text: String, _ old: String) -> String? {
    var lines = text.components(separatedBy: "\n")
    let ol = old.components(separatedBy: "\n").map { trimEndStr(Substring($0)) }
    guard !ol.isEmpty else { return nil }
    var i = 0
    while i + ol.count <= lines.count {
        var ok = true
        for k in 0..<ol.count where trimEndStr(Substring(lines[i + k])) != ol[k] { ok = false; break }
        if !ok { i += 1; continue }
        var n = ol.count
        var start = i
        if i + n < lines.count && blank(lines[i + n]) { n += 1 }
        else if i > 0 && blank(lines[i - 1]) { start -= 1; n += 1 }
        lines.removeSubrange(start..<start + n)
        return lines.joined(separator: "\n")
    }
    return nil
}

public func balanceLine(_ date: String, _ account: String, _ amount: Double, _ currency: String) -> String {
    let left = "\(date) balance \(account)"
    let ns = toFixed(amount, 2)
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
    if lines[idx].contains(lastWord) { return text }
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
