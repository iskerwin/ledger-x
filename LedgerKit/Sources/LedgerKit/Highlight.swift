import Foundation

// Syntax colouring for the source text the app shows: Beancount and BQL. Only says what each piece of a line
// is; the text itself is never changed. Ranges are UTF-16 offsets (NSString / NSAttributedString).

public enum CodeLanguage: String { case beancount, bql, plain }

public enum CodeToken: String, CaseIterable {
    case date, flag, keyword, string, account, number, currency, tag, link, metaKey, comment, op, function
}

public struct CodeSpan: Equatable {
    public let location: Int
    public let length: Int
    public let kind: CodeToken
    public init(_ location: Int, _ length: Int, _ kind: CodeToken) { self.location = location; self.length = length; self.kind = kind }
}

/// the coloured pieces of `text` (all of it, or the lines of `range`), offsets into the whole text
public func codeSpans(_ text: String, _ lang: CodeLanguage, in range: NSRange? = nil) -> [CodeSpan] {
    guard lang != .plain else { return [] }
    let ns = text as NSString
    let whole = range.map { ns.lineRange(for: $0) } ?? NSRange(location: 0, length: ns.length)
    var out: [CodeSpan] = []
    var pos = whole.location
    let end = whole.location + whole.length
    while pos < end {
        var lineEnd = 0, contentsEnd = 0
        ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: pos, length: 0))
        let line = Array(ns.substring(with: NSRange(location: pos, length: contentsEnd - pos)).utf16)
        for s in (lang == .beancount ? beancountLine(line) : bqlLine(line)) {
            out.append(CodeSpan(pos + s.location, s.length, s.kind))
        }
        if lineEnd <= pos { break }
        pos = lineEnd
    }
    return out
}

// MARK: - characters (UTF-16)

private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
private func isUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }
private func isLower(_ c: UInt16) -> Bool { c >= 97 && c <= 122 }
private func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }
/// letters of other scripts (accounts and tags can have them); surrogates count as one
private func isOther(_ c: UInt16) -> Bool { c >= 0x80 }
private func isWordChar(_ c: UInt16) -> Bool {
    isDigit(c) || isUpper(c) || isLower(c) || isOther(c) || c == 45 /* - */ || c == 95 /* _ */ || c == 58 /* : */
        || c == 39 /* ' */ || c == 46 /* . */
}
private func scalar(_ s: String) -> UInt16 { s.utf16.first! }

/// a quoted string from `i` (at the quote) to its closing quote, or the end of the line
private func stringEnd(_ l: [UInt16], _ i: Int, quote: UInt16) -> Int {
    var j = i + 1
    while j < l.count {
        if l[j] == 92 /* \ */ { j += 2; continue }
        if l[j] == quote { return j + 1 }
        j += 1
    }
    return l.count
}

/// a number from `i`: digits with , and one ., an optional sign in front (when no word is before it)
private func numberEnd(_ l: [UInt16], _ i: Int) -> Int? {
    var j = i
    if j < l.count, l[j] == 45 || l[j] == 43 { j += 1 }
    guard j < l.count, isDigit(l[j]) else { return nil }
    while j < l.count, isDigit(l[j]) || l[j] == 44 || l[j] == 46 { j += 1 }
    // 2026-10-14 is a date, Assets:X1 a word: a number stops at a word boundary
    if j < l.count, isUpper(l[j]) || isLower(l[j]) || l[j] == 58 { return nil }
    return j
}

/// YYYY-MM-DD or YYYY/MM/DD from `i`
private func isDate(_ l: [UInt16], _ i: Int) -> Bool {
    guard i + 10 <= l.count else { return false }
    let sep = l[i + 4]
    guard sep == 45 || sep == 47, l[i + 7] == sep else { return false }
    for k in [0, 1, 2, 3, 5, 6, 8, 9] where !isDigit(l[i + k]) { return false }
    return i + 10 == l.count || !isDigit(l[i + 10])
}

// MARK: - Beancount

private let beancountKeywords: Set<String> = [
    "open", "close", "commodity", "balance", "pad", "note", "document", "event", "price", "query", "custom", "txn",
    "option", "plugin", "include", "pushtag", "poptag", "pushmeta", "popmeta", "TRUE", "FALSE", "NULL",
]
private let roots: Set<String> = ["Assets", "Liabilities", "Equity", "Income", "Expenses"]

func beancountLine(_ l: [UInt16]) -> [CodeSpan] {
    var out: [CodeSpan] = []
    // org-mode headings (`* 2026`) are skipped by Beancount like comments
    if l.first == scalar("*") { return [CodeSpan(0, l.count, .comment)] }
    var i = 0
    var lead = true   // nothing but spaces before: a metadata key can start here
    var prev: UInt16 = 32
    while i < l.count {
        let c = l[i]
        if isSpace(c) { i += 1; prev = c; continue }
        let start = i
        if c == scalar(";") {
            out.append(CodeSpan(i, l.count - i, .comment)); break
        } else if c == scalar("\"") {
            i = stringEnd(l, i, quote: c)
            out.append(CodeSpan(start, i - start, .string))
        } else if isDigit(c), isDate(l, i) {
            i += 10
            out.append(CodeSpan(start, 10, .date))
        } else if (isDigit(c) || ((c == 45 || c == 43) && isSpace(prev))), let e = numberEnd(l, i) {
            i = e
            out.append(CodeSpan(start, i - start, .number))
        } else if c == scalar("#") || c == scalar("^") {
            i += 1
            while i < l.count, !isSpace(l[i]), l[i] != scalar("\""), l[i] != scalar(";") { i += 1 }
            if i - start > 1 { out.append(CodeSpan(start, i - start, c == scalar("#") ? .tag : .link)) }
        } else if (c == scalar("*") || c == scalar("!")) && (i + 1 == l.count || isSpace(l[i + 1])) {
            i += 1
            out.append(CodeSpan(start, 1, .flag))
        } else if c == scalar("@") || c == scalar("{") || c == scalar("}") || c == scalar("~") {
            i += 1
            while i < l.count, l[i] == c { i += 1 }
            out.append(CodeSpan(start, i - start, .op))
        } else if isUpper(c) || isLower(c) || isOther(c) {
            while i < l.count, isWordChar(l[i]) { i += 1 }
            var word = String(utf16CodeUnits: Array(l[start..<i]), count: i - start)
            if lead, isLower(c), word.hasSuffix(":") {
                // `payee:` metadata key (the colon belongs to it)
                out.append(CodeSpan(start, i - start, .metaKey))
            } else {
                // a trailing . or : is punctuation, not part of the word
                while word.hasSuffix(".") || word.hasSuffix(":") { word.removeLast(); i -= 1 }
                if let colon = word.firstIndex(of: ":"), roots.contains(String(word[..<colon])) || isUpper(c) {
                    out.append(CodeSpan(start, i - start, .account))
                } else if beancountKeywords.contains(word) {
                    out.append(CodeSpan(start, i - start, .keyword))
                } else if isUpper(c), word.utf16.allSatisfy({ isUpper($0) || isDigit($0) || $0 == 39 || $0 == 46 || $0 == 95 || $0 == 45 }) {
                    out.append(CodeSpan(start, i - start, .currency))
                }
                if i == start { i += 1 }
            }
        } else {
            i += 1
        }
        lead = false
        prev = i > 0 ? l[i - 1] : 32
    }
    return out
}

// MARK: - BQL

private let bqlKeywords: Set<String> = [
    "SELECT", "FROM", "WHERE", "GROUP", "BY", "ORDER", "LIMIT", "AS", "AND", "OR", "NOT", "IN", "DESC", "ASC",
    "DISTINCT", "PIVOT", "HAVING", "BALANCES", "JOURNAL", "PRINT", "AT", "OPEN", "ON", "CLOSE", "CLEAR", "TRUE",
    "FALSE", "NULL", "IS", "LIKE", "BETWEEN",
]

func bqlLine(_ l: [UInt16]) -> [CodeSpan] {
    var out: [CodeSpan] = []
    var i = 0
    var prev: UInt16 = 32
    while i < l.count {
        let c = l[i]
        if isSpace(c) { i += 1; prev = c; continue }
        let start = i
        if c == scalar(";") || (c == 45 && i + 1 < l.count && l[i + 1] == 45) {
            // ; and -- start a comment in .bql files
            out.append(CodeSpan(i, l.count - i, .comment)); break
        } else if c == scalar("'") || c == scalar("\"") {
            i = stringEnd(l, i, quote: c)
            out.append(CodeSpan(start, i - start, .string))
        } else if isDigit(c), isDate(l, i) {
            i += 10
            out.append(CodeSpan(start, 10, .date))
        } else if isDigit(c) || ((c == 45) && !(isUpper(prev) || isLower(prev) || isDigit(prev))), let e = numberEnd(l, i) {
            i = e
            out.append(CodeSpan(start, i - start, .number))
        } else if isUpper(c) || isLower(c) || c == 95 {
            while i < l.count, isUpper(l[i]) || isLower(l[i]) || isDigit(l[i]) || l[i] == 95 || l[i] == 46 { i += 1 }
            let word = String(utf16CodeUnits: Array(l[start..<i]), count: i - start)
            var j = i
            while j < l.count, isSpace(l[j]) { j += 1 }
            if bqlKeywords.contains(word.uppercased()) {
                out.append(CodeSpan(start, i - start, .keyword))
            } else if j < l.count, l[j] == scalar("(") {
                out.append(CodeSpan(start, i - start, .function))
            }
        } else if c == scalar("~") || c == scalar("=") || c == scalar("<") || c == scalar(">") || c == scalar("!") {
            i += 1
            while i < l.count, l[i] == scalar("=") || l[i] == scalar("~") { i += 1 }
            out.append(CodeSpan(start, i - start, .op))
        } else {
            i += 1
        }
        prev = i > 0 ? l[i - 1] : 32
    }
    return out
}
