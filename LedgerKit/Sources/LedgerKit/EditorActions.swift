import Foundation

// The source editor's shortcut bar: the edits that look at the text around the cursor (the entry it is in).
// Offsets are UTF-16 (NSString / UITextView).

private let headerRE = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2})[ \t]+([*!])(?=[ \t]|$)"#)

/// the lines of the entry the cursor is in: from its first line (the one that doesn't start with a space) down to
/// before the next blank line or the next entry
public func entryRange(_ text: String, at cursor: Int) -> NSRange? {
    let ns = text as NSString
    guard ns.length > 0 else { return nil }
    var line = ns.lineRange(for: NSRange(location: min(cursor, ns.length), length: 0))
    func blank(_ r: NSRange) -> Bool { ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func indented(_ r: NSRange) -> Bool { let s = ns.substring(with: r); return s.hasPrefix(" ") || s.hasPrefix("\t") }
    if blank(line) { return nil }
    // up to the entry's first line
    while indented(line), line.location > 0 {
        let prev = ns.lineRange(for: NSRange(location: line.location - 1, length: 0))
        if blank(prev) { break }
        line = prev
    }
    var end = NSMaxRange(line)
    while end < ns.length {
        let next = ns.lineRange(for: NSRange(location: end, length: 0))
        if blank(next) || !indented(next) { break }
        end = NSMaxRange(next)
    }
    return NSRange(location: line.location, length: end - line.location)
}

/// the transaction the cursor is in, with its flag changed (* ↔ !); nil when the cursor isn't in one
public func toggledFlag(_ text: String, at cursor: Int) -> (range: NSRange, with: String)? {
    let ns = text as NSString
    guard let e = entryRange(text, at: cursor) else { return nil }
    let header = ns.lineRange(for: NSRange(location: e.location, length: 0))
    let line = ns.substring(with: header)
    guard let m = headerRE.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
    let flag = (line as NSString).substring(with: m.range(at: 2))
    return (NSRange(location: header.location + m.range(at: 2).location, length: 1), flag == "*" ? "!" : "*")
}

/// the entry the cursor is in, laid out (amounts right-aligned); nil when it is already, or there is none
public func alignedEntry(_ text: String, at cursor: Int) -> (range: NSRange, with: String)? {
    let ns = text as NSString
    guard let e = entryRange(text, at: cursor) else { return nil }
    let old = ns.substring(with: e)
    let trailing = old.hasSuffix("\n") ? "\n" : ""
    let new = alignText(String(old.dropLast(trailing.count))) + trailing
    return new == old ? nil : (e, new)
}

/// a new transaction to fill in, and where the cursor goes (inside the payee's quotes)
public func transactionTemplate(date: String) -> (text: String, cursor: Int) {
    let head = "\(date) * \""
    return (head + "\" \"\"\n  \n  ", (head as NSString).length)
}
