import Foundation

typealias US = Unicode.Scalar

/// Thousands separators must group correctly: "1,234,567" is fine, but
/// "1,2,3", "12,34", ",123" and "123," are rejected instead of being silently
/// stripped (which used to turn "1,2,3" into 123). Shared by the ledger parser
/// (`Scan.lit`) and the entry form (`evalExpr`) so both paths agree.
func thousandsGroupingOK(_ s: String) -> Bool {
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if c.isASCII && (c.isNumber || c == ",") {
            var j = i
            while j < s.endIndex, s[j].isASCII && (s[j].isNumber || s[j] == ",") { j = s.index(after: j) }
            if !validThousandsGrouping(String(s[i..<j])) { return false }
            i = j
        } else {
            i = s.index(after: i)
        }
    }
    return true
}

private func validThousandsGrouping(_ run: String) -> Bool {
    guard run.contains(",") else { return true }
    let parts = run.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return true }
    guard let first = parts.first, (1...3).contains(first.count),
          first.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
    return parts.dropFirst().allSatisfy { $0.count == 3 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }
}

@inline(__always) func isWS(_ c: US) -> Bool { c.properties.isWhitespace || c.value == 0xFEFF }
@inline(__always) func isDigit(_ c: US) -> Bool { c.value >= 48 && c.value <= 57 }
@inline(__always) func isAZ(_ c: US) -> Bool { c.value >= 65 && c.value <= 90 }
@inline(__always) func isaz(_ c: US) -> Bool { c.value >= 97 && c.value <= 122 }
@inline(__always) func isWordChar(_ c: US) -> Bool { isAZ(c) || isaz(c) || isDigit(c) || c == "_" }

@inline(__always) func isLu(_ c: US) -> Bool {
    if c.value < 128 { return isAZ(c) }
    return c.properties.generalCategory == .uppercaseLetter
}
@inline(__always) func isLo(_ c: US) -> Bool {
    if c.value < 128 { return false }
    return c.properties.generalCategory == .otherLetter
}
@inline(__always) func isL(_ c: US) -> Bool {
    if c.value < 128 { return isAZ(c) || isaz(c) }
    switch c.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
    default: return false
    }
}
@inline(__always) func isN(_ c: US) -> Bool {
    if c.value < 128 { return isDigit(c) }
    switch c.properties.generalCategory {
    case .decimalNumber, .letterNumber, .otherNumber: return true
    default: return false
    }
}
@inline(__always) func isCcyBody(_ c: US) -> Bool { isAZ(c) || isDigit(c) || c == "'" || c == "." || c == "_" || c == "-" }

let FLAGS: Set<String> = ["*", "!", "&", "#", "?", "%", "P", "S", "T", "C", "U", "R", "M"]

func scalars(_ s: String) -> [US] { Array(s.unicodeScalars) }
func str(_ a: ArraySlice<US>) -> String { var v = String.UnicodeScalarView(); v.append(contentsOf: a); return String(v) }
func str(_ a: [US]) -> String { str(a[...]) }

/// length of an account name at the start of `s[i...]`, or 0
func accountLength(_ s: [US], _ i: Int) -> Int {
    let n = s.count
    guard i < n, isLu(s[i]) else { return 0 }
    var j = i + 1
    while j < n, isL(s[j]) || isN(s[j]) || s[j] == "-" { j += 1 }
    var comps = 0
    while j + 1 < n, s[j] == ":", isLu(s[j + 1]) || isN(s[j + 1]) || isLo(s[j + 1]) {
        j += 2
        while j < n, isL(s[j]) || isN(s[j]) || s[j] == "-" { j += 1 }
        comps += 1
    }
    return comps > 0 ? j - i : 0
}

public func isAccountName(_ s: String) -> Bool {
    let a = scalars(s)
    return accountLength(a, 0) == a.count && !a.isEmpty
}

/// length of a currency at the start of `s[i...]`, or 0
func currencyLength(_ s: [US], _ i: Int) -> Int {
    let n = s.count
    var j = i
    if j < n, s[j] == "/" { j += 1 }
    guard j < n, isAZ(s[j]) else { return 0 }
    j += 1
    let runStart = j
    while j < n, isCcyBody(s[j]) { j += 1 }
    let run = j - runStart
    if j < n, isaz(s[j]) { return 0 }
    if run == 0 { return j - i }
    let last = s[j - 1]
    guard run <= 23, isAZ(last) || isDigit(last) else { return 0 }
    return j - i
}

final class Scan {
    let s: [US]
    var i = 0
    init(_ text: String) { s = scalars(text) }
    init(_ a: [US]) { s = a }

    @discardableResult func ws() -> Scan { while i < s.count, isWS(s[i]) { i += 1 }; return self }
    func eof() -> Bool { ws(); return i >= s.count }
    func peek() -> US? { i < s.count ? s[i] : nil }
    func peek2() -> String { str(s[i..<min(i + 2, s.count)]) }
    func at(_ k: Int) -> US? { k < s.count && k >= 0 ? s[k] : nil }
    func rest() -> String { str(s[min(i, s.count)...]) }

    func eat(_ t: String) -> Bool {
        ws()
        let a = scalars(t)
        guard i + a.count <= s.count else { return false }
        for k in 0..<a.count where s[i + k] != a[k] { return false }
        i += a.count
        return true
    }

    func string() -> String? {
        ws()
        guard i < s.count, s[i] == "\"" else { return nil }
        var out = String.UnicodeScalarView()
        var j = i + 1
        while j < s.count {
            let c = s[j]
            if c == "\\", j + 1 < s.count {
                j += 1
                let nx = s[j]
                if nx == "n" { out.append("\n") } else if nx == "t" { out.append("\t") } else { out.append(nx) }
                j += 1
                continue
            }
            if c == "\"" { i = j + 1; return String(out) }
            out.append(c)
            j += 1
        }
        return nil
    }

    func account() -> String? {
        ws()
        let n = accountLength(s, i)
        guard n > 0 else { return nil }
        defer { i += n }
        return str(s[i..<i + n])
    }

    func currency() -> String? {
        ws()
        let n = currencyLength(s, i)
        guard n > 0 else { return nil }
        defer { i += n }
        return str(s[i..<i + n])
    }

    func date() -> String? {
        ws()
        guard let d = dateAt(s, i) else { return nil }
        i += 10
        return d
    }

    func tagOrLink() -> (isTag: Bool, value: String)? {
        ws()
        guard i < s.count, s[i] == "#" || s[i] == "^" else { return nil }
        var j = i + 1
        while j < s.count {
            let c = s[j]
            if isAZ(c) || isaz(c) || isDigit(c) || c == "-" || c == "_" || c == "/" || c == "." || isL(c) { j += 1 } else { break }
        }
        guard j > i + 1 else { return nil }
        let r = (isTag: s[i] == "#", value: str(s[i + 1..<j]))
        i = j
        return r
    }

    // arithmetic expression: + - * / ( ) unary, numbers with validated thousands commas
    private var nDigits = 0
    private var nOK = true

    private func lit() -> Double {
        ws()
        var j = i
        var raw = String.UnicodeScalarView()
        var t = String.UnicodeScalarView()
        if j < s.count, isDigit(s[j]) {
            while j < s.count, isDigit(s[j]) || s[j] == "," { raw.append(s[j]); if s[j] != "," { t.append(s[j]) }; j += 1 }
            guard thousandsGroupingOK(String(raw)) else { nOK = false; return 0 }
            if j < s.count, s[j] == "." {
                t.append("."); j += 1
                var f = 0
                while j < s.count, isDigit(s[j]) { t.append(s[j]); j += 1; f += 1 }
                nDigits = max(nDigits, f)
            }
        } else if j + 1 < s.count, s[j] == ".", isDigit(s[j + 1]) {
            t.append("0"); t.append("."); j += 1
            var f = 0
            while j < s.count, isDigit(s[j]) { t.append(s[j]); j += 1; f += 1 }
            nDigits = max(nDigits, f)
        } else {
            nOK = false
            return 0
        }
        i = j
        var ts = String(t)
        if ts.hasSuffix(".") { ts += "0" }
        guard let v = Double(ts) else { nOK = false; return 0 }
        return v
    }

    private func factor() -> Double {
        ws()
        guard i < s.count else { nOK = false; return 0 }
        let c = s[i]
        if c == "-" { i += 1; return -factor() }
        if c == "+" { i += 1; return factor() }
        if c == "(" {
            i += 1
            let v = expr()
            ws()
            if i < s.count, s[i] == ")" { i += 1 } else { nOK = false }
            return v
        }
        return lit()
    }

    private func term() -> Double {
        var v = factor()
        while true {
            let j = i
            ws()
            if i < s.count, s[i] == "*" || s[i] == "/" {
                let op = s[i]
                i += 1
                let r = factor()
                v = op == "*" ? v * r : v / r
            } else {
                i = j
                return v
            }
        }
    }

    private func expr() -> Double {
        var v = term()
        while true {
            let j = i
            ws()
            if i < s.count, s[i] == "+" || s[i] == "-" {
                // a binary +/- must be followed by something numeric
                var k = i + 1
                while k < s.count, isWS(s[k]) { k += 1 }
                if k < s.count, isDigit(s[k]) || s[k] == "." || s[k] == "(" {
                    let op = s[i]
                    i += 1
                    let r = term()
                    v = op == "+" ? v + r : v - r
                    continue
                }
            }
            i = j
            return v
        }
    }

    func number() -> (value: Double, digits: Int)? {
        let save = i
        nDigits = 0
        nOK = true
        ws()
        guard i < s.count else { return nil }
        let c0 = s[i]
        guard c0 == "-" || c0 == "+" || c0 == "(" || c0 == "." || isDigit(c0) else { return nil }
        let v = expr()
        if !nOK || !v.isFinite { i = save; return nil }
        return (v, nDigits)
    }
}

/// `YYYY-MM-DD` (or with `/`) at position i, normalised to dashes
func dateAt(_ s: [US], _ i: Int) -> String? {
    guard i + 10 <= s.count else { return nil }
    for k in [0, 1, 2, 3, 5, 6, 8, 9] where !isDigit(s[i + k]) { return nil }
    guard s[i + 4] == "-" || s[i + 4] == "/", s[i + 7] == "-" || s[i + 7] == "/" else { return nil }
    return str(s[i..<i + 4]) + "-" + str(s[i + 5..<i + 7]) + "-" + str(s[i + 8..<i + 10])
}

/// remove a ; comment outside of strings
func stripComment(_ s: [US]) -> [US] {
    var q = false
    var i = 0
    while i < s.count {
        let c = s[i]
        if c == "\\" && q { i += 2; continue }
        if c == "\"" { q.toggle() } else if c == ";" && !q { return Array(s[..<i]) }
        i += 1
    }
    return s
}

/// true = an unterminated string continues on the next line
func quoteOpen(_ s: [US]) -> Bool {
    var q = false
    var i = 0
    while i < s.count {
        let c = s[i]
        if c == "\\" && q { i += 2; continue }
        if c == "\"" { q.toggle() } else if c == ";" && !q { break }
        i += 1
    }
    return q
}

func trimEnd(_ s: [US]) -> [US] {
    var e = s.count
    while e > 0, isWS(s[e - 1]) { e -= 1 }
    return Array(s[..<e])
}

func isBlank(_ s: [US]) -> Bool { s.allSatisfy(isWS) }

/// metadata value: string, date, number[ currency], bool, else the raw text
func parseValue(_ raw: String) -> MetaValue? {
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    let sc = Scan(t)
    if let st = sc.string() { return .string(st) }
    if t == "TRUE" { return .bool(true) }
    if t == "FALSE" { return .bool(false) }
    let save = sc.i
    if let d = sc.date(), sc.eof() { return .date(d) }
    sc.i = save
    if let n = sc.number() {
        let c = sc.currency()
        if sc.eof() { return c != nil ? .amount(n.value, c!) : .number(n.value) }
    }
    return .raw(t)
}
