import Foundation

// A practical subset of Beancount's query language (BQL), run over postings:
//
//   SELECT [DISTINCT] expr [AS name], ...
//   [FROM expr] [WHERE expr]
//   [GROUP BY expr|name|index, ...] [ORDER BY expr|name|index [ASC|DESC], ...] [LIMIT n]
//   BALANCES [FROM expr] [WHERE expr]
//   JOURNAL "account-regex" [FROM expr]
//
// Columns: date year month day quarter flag payee narration description tags links
//          account position units number currency cost_number cost_currency price weight
//          balance filename lineno id
// Functions: SUM COUNT FIRST LAST MIN MAX  (aggregates)
//            YEAR MONTH DAY QUARTER YMONTH PARENT LEAF ROOT GREP UNITS COST NUMBER CURRENCY
//            ABS NEG CONVERT VALUE STR LOWER UPPER LENGTH COALESCE ONLY POSSIGN
// Operators: = != <> < <= > >= ~ !~ IN, NOT IN, AND OR NOT, + - * /, IS NULL

// MARK: - values

/// a multi-currency sum (what SUM(position) returns)
public struct Inventory: Equatable {
    public var order: [String] = []
    public var amounts: [String: Double] = [:]
    public init() {}
    public mutating func add(_ n: Double, _ c: String) {
        if amounts[c] == nil { order.append(c) }
        amounts[c, default: 0] += n
    }
    public var nonZero: [(String, Double)] { order.compactMap { c in abs(amounts[c]!) > 1e-9 ? (c, amounts[c]!) : nil } }
    public var isEmpty: Bool { nonZero.isEmpty }
}

public enum QValue: Equatable {
    case null
    case number(Double)
    case string(String)
    case date(String)
    case bool(Bool)
    case amount(Double, String)
    case inventory(Inventory)
    case set([String])

    public var text: String {
        switch self {
        case .null: return ""
        case .number(let n): return QValue.fmt(n)
        case .string(let s): return s
        case .date(let d): return d
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .amount(let n, let c): return QValue.fmt(n) + " " + c
        case .inventory(let i): return i.nonZero.map { QValue.fmt($0.1) + " " + $0.0 }.joined(separator: ", ")
        case .set(let s): return s.joined(separator: ", ")
        }
    }

    static func fmt(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 { return String(Int64(n)) }
        let s = toFixed(n, 2)
        // keep more digits when two decimals would hide them
        if abs(Double(s)! - n) > 1e-9 { return jsNumberString(roundTo(n, 6)) }
        return s
    }

    /// a number to sort and compare by
    public var sortNumber: Double? {
        switch self {
        case .number(let n): return n
        case .amount(let n, _): return n
        case .inventory(let i): return i.nonZero.first?.1 ?? 0
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var isNumeric: Bool { sortNumber != nil && !(self == .null) }

    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty
        case .set(let s): return !s.isEmpty
        case .inventory(let i): return !i.isEmpty
        default: return true
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .date(let d): return d
        default: return nil
        }
    }
}

public struct QueryError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    init(_ m: String) { message = m }
}

public struct QueryResult {
    public var columns: [String]
    public var rows: [[QValue]]
    /// columns holding numbers or amounts (right-aligned in tables)
    public var numeric: [Bool]
}

// MARK: - tokens

enum QTok: Equatable {
    case ident(String)     // as written (keywords compared case-insensitively)
    case string(String)
    case number(Double)
    case date(String)
    case op(String)
    case end
}

func qTokenize(_ s: String) throws -> [QTok] {
    var out: [QTok] = []
    let a = Array(s.unicodeScalars)
    var i = 0
    func at(_ k: Int) -> US? { k < a.count ? a[k] : nil }
    while i < a.count {
        let c = a[i]
        if isWS(c) { i += 1; continue }
        // comments
        if c == "-", at(i + 1) == "-" { while i < a.count, a[i] != "\n" { i += 1 }; continue }
        if c == ";" { i += 1; continue }
        if c == "\"" || c == "'" {
            var j = i + 1
            var v = String.UnicodeScalarView()
            while j < a.count, a[j] != c {
                if a[j] == "\\", j + 1 < a.count { j += 1 }
                v.append(a[j]); j += 1
            }
            guard j < a.count else { throw QueryError(tr("字符串缺少结束引号", "Unterminated string")) }
            out.append(.string(String(v)))
            i = j + 1
            continue
        }
        if let d = dateAt(a, i), (i + 10 >= a.count || !isDigit(a[i + 10])) {
            out.append(.date(d)); i += 10; continue
        }
        if isDigit(c) || (c == "." && at(i + 1).map(isDigit) == true) {
            var j = i
            while j < a.count, isDigit(a[j]) || a[j] == "." { j += 1 }
            out.append(.number(Double(str(a[i..<j])) ?? 0))
            i = j
            continue
        }
        if isAZ(c) || isaz(c) || c == "_" || c.value > 127 {
            var j = i
            // identifiers may contain ":" so account names can be written bare in JOURNAL
            while j < a.count, isWordChar(a[j]) || a[j].value > 127 || a[j] == "-" && j > i && j + 1 < a.count && isWordChar(a[j + 1]) { j += 1 }
            out.append(.ident(str(a[i..<j])))
            i = j
            continue
        }
        let two = i + 1 < a.count ? str(a[i...i + 1]) : ""
        if ["<=", ">=", "!=", "<>", "!~", "=="].contains(two) { out.append(.op(two == "==" ? "=" : two == "<>" ? "!=" : two)); i += 2; continue }
        if "=<>~+-*/(),".unicodeScalars.contains(c) { out.append(.op(String(c))); i += 1; continue }
        throw QueryError(tr("无法识别的字符：\(c)", "Unexpected character: \(c)"))
    }
    out.append(.end)
    return out
}

// MARK: - syntax tree

indirect enum QExpr {
    case lit(QValue)
    case column(String)
    case call(String, [QExpr], star: Bool)
    case unary(String, QExpr)
    case binary(String, QExpr, QExpr)
    case inList(QExpr, [QExpr], negated: Bool)
    case isNull(QExpr, negated: Bool)

    static let aggregates: Set<String> = ["SUM", "COUNT", "FIRST", "LAST", "MIN", "MAX"]

    var hasAggregate: Bool {
        switch self {
        case .lit, .column: return false
        case .call(let n, let args, _): return QExpr.aggregates.contains(n) || args.contains { $0.hasAggregate }
        case .unary(_, let e): return e.hasAggregate
        case .binary(_, let l, let r): return l.hasAggregate || r.hasAggregate
        case .inList(let e, let l, _): return e.hasAggregate || l.contains { $0.hasAggregate }
        case .isNull(let e, _): return e.hasAggregate
        }
    }

    /// a readable name for a result column
    var name: String {
        switch self {
        case .lit(let v): return v.text
        case .column(let c): return c
        case .call(let n, let args, let star): return n.lowercased() + "(" + (star ? "*" : args.map { $0.name }.joined(separator: ", ")) + ")"
        case .unary(let op, let e): return op + e.name
        case .binary(let op, let l, let r): return l.name + " " + op + " " + r.name
        case .inList(let e, _, _): return e.name
        case .isNull(let e, _): return e.name
        }
    }
}

struct QTarget { var expr: QExpr; var alias: String? }
struct QOrder { var expr: QExpr; var desc: Bool }

struct QStatement {
    var targets: [QTarget] = []
    var star = false
    var distinct = false
    var from: QExpr?
    var whereExpr: QExpr?
    var groupBy: [QExpr]?
    var orderBy: [QOrder] = []
    var limit: Int?
}

final class QParser {
    var t: [QTok]
    var i = 0
    init(_ toks: [QTok]) { t = toks }

    var cur: QTok { t[i] }
    func kw(_ k: String) -> Bool { if case .ident(let s) = cur, s.uppercased() == k { return true }; return false }
    func eatKw(_ k: String) -> Bool { if kw(k) { i += 1; return true }; return false }
    func isOp(_ o: String) -> Bool { cur == .op(o) }
    func eatOp(_ o: String) -> Bool { if isOp(o) { i += 1; return true }; return false }
    func expectKw(_ k: String) throws { guard eatKw(k) else { throw QueryError(tr("此处应为 \(k)", "Expected \(k)")) } }

    func statement() throws -> QStatement {
        if eatKw("BALANCES") {
            var st = QStatement()
            st.targets = [QTarget(expr: .column("account"), alias: nil), QTarget(expr: .call("SUM", [.column("position")], star: false), alias: "balance")]
            if eatKw("FROM") { st.from = try expr() }
            if eatKw("WHERE") { st.whereExpr = try expr() }
            st.groupBy = [.column("account")]
            st.orderBy = [QOrder(expr: .column("account"), desc: false)]
            try finish()
            return st
        }
        if eatKw("JOURNAL") {
            var st = QStatement()
            st.targets = ["date", "flag", "payee", "narration", "account", "position", "balance"].map { QTarget(expr: .column($0), alias: nil) }
            var pattern: String?
            if case .string(let s) = cur { pattern = s; i += 1 } else if case .ident(let s) = cur, !["FROM", "WHERE"].contains(s.uppercased()) { pattern = s; i += 1 }
            if eatKw("FROM") { st.from = try expr() }
            if eatKw("WHERE") { st.whereExpr = try expr() }
            if let p = pattern {
                let cond = QExpr.binary("~", .column("account"), .lit(.string(p)))
                st.whereExpr = st.whereExpr.map { .binary("AND", cond, $0) } ?? cond
            }
            try finish()
            return st
        }
        try expectKw("SELECT")
        var st = QStatement()
        st.distinct = eatKw("DISTINCT")
        if eatOp("*") {
            st.star = true
        } else {
            repeat {
                let e = try expr()
                var alias: String? = nil
                if eatKw("AS") {
                    guard case .ident(let a) = cur else { throw QueryError(tr("AS 之后应为列别名", "Expected a column alias after AS")) }
                    alias = a; i += 1
                }
                st.targets.append(QTarget(expr: e, alias: alias))
            } while eatOp(",")
        }
        if eatKw("FROM") {
            // "FROM year = 2026" filters whole transactions; OPEN/CLOSE/CLEAR are accepted and ignored
            if !kw("WHERE") && !kw("GROUP") && !kw("ORDER") && !kw("LIMIT") && cur != .end { st.from = try expr() }
            while eatKw("OPEN") || eatKw("CLOSE") || eatKw("CLEAR") || eatKw("ON") { if case .date = cur { i += 1 } }
        }
        if eatKw("WHERE") { st.whereExpr = try expr() }
        if eatKw("GROUP") {
            try expectKw("BY")
            var g: [QExpr] = []
            repeat { g.append(try expr()) } while eatOp(",")
            st.groupBy = g
            if eatKw("HAVING") { _ = try expr() }
        }
        if eatKw("ORDER") {
            try expectKw("BY")
            repeat {
                let e = try expr()
                var desc = false
                if eatKw("DESC") { desc = true } else { _ = eatKw("ASC") }
                st.orderBy.append(QOrder(expr: e, desc: desc))
            } while eatOp(",")
        }
        if eatKw("LIMIT") {
            guard case .number(let n) = cur else { throw QueryError(tr("LIMIT 之后应为整数", "Expected an integer after LIMIT")) }
            st.limit = Int(n); i += 1
        }
        if eatKw("PIVOT") { throw QueryError(tr("暂不支持 PIVOT BY", "PIVOT BY is not supported")) }
        try finish()
        return st
    }

    func finish() throws {
        guard cur == .end else {
            throw QueryError(tr("无法解析的内容：\(describe(cur))", "Unexpected input: \(describe(cur))"))
        }
    }

    func describe(_ t: QTok) -> String {
        switch t {
        case .ident(let s): return s
        case .string(let s): return "\"\(s)\""
        case .number(let n): return QValue.fmt(n)
        case .date(let d): return d
        case .op(let o): return o
        case .end: return tr("结尾", "end of query")
        }
    }

    func expr() throws -> QExpr { try orExpr() }
    func orExpr() throws -> QExpr {
        var l = try andExpr()
        while eatKw("OR") { l = .binary("OR", l, try andExpr()) }
        return l
    }
    func andExpr() throws -> QExpr {
        var l = try notExpr()
        while eatKw("AND") { l = .binary("AND", l, try notExpr()) }
        return l
    }
    func notExpr() throws -> QExpr {
        if eatKw("NOT") { return .unary("NOT", try notExpr()) }
        return try comparison()
    }
    func comparison() throws -> QExpr {
        let l = try additive()
        for o in ["=", "!=", "<", "<=", ">", ">=", "~", "!~"] where isOp(o) {
            i += 1
            return .binary(o, l, try additive())
        }
        if kw("NOT"), i + 1 < t.count, case .ident(let s) = t[i + 1], s.uppercased() == "IN" {
            i += 2
            return .inList(l, try list(), negated: true)
        }
        if eatKw("IN") { return .inList(l, try list(), negated: false) }
        if eatKw("IS") {
            let neg = eatKw("NOT")
            try expectKw("NULL")
            return .isNull(l, negated: neg)
        }
        return l
    }
    func list() throws -> [QExpr] {
        guard eatOp("(") else { return [try additive()] }   // "x IN tags" style
        var out: [QExpr] = []
        if !isOp(")") { repeat { out.append(try expr()) } while eatOp(",") }
        guard eatOp(")") else { throw QueryError(tr("缺少右括号", "Missing closing parenthesis")) }
        return out
    }
    func additive() throws -> QExpr {
        var l = try multiplicative()
        while isOp("+") || isOp("-") {
            let o = isOp("+") ? "+" : "-"; i += 1
            l = .binary(o, l, try multiplicative())
        }
        return l
    }
    func multiplicative() throws -> QExpr {
        var l = try unary()
        while isOp("*") || isOp("/") {
            let o = isOp("*") ? "*" : "/"; i += 1
            l = .binary(o, l, try unary())
        }
        return l
    }
    func unary() throws -> QExpr {
        if eatOp("-") { return .unary("-", try unary()) }
        if eatOp("+") { return try unary() }
        return try primary()
    }
    func primary() throws -> QExpr {
        switch cur {
        case .number(let n): i += 1; return .lit(.number(n))
        case .string(let s): i += 1; return .lit(.string(s))
        case .date(let d): i += 1; return .lit(.date(d))
        case .op("("):
            i += 1
            let e = try expr()
            guard eatOp(")") else { throw QueryError(tr("缺少右括号", "Missing closing parenthesis")) }
            return e
        case .ident(let s):
            i += 1
            let up = s.uppercased()
            if up == "TRUE" { return .lit(.bool(true)) }
            if up == "FALSE" { return .lit(.bool(false)) }
            if up == "NULL" { return .lit(.null) }
            if eatOp("(") {
                if eatOp("*") {
                    guard eatOp(")") else { throw QueryError(tr("缺少右括号", "Missing closing parenthesis")) }
                    return .call(up, [], star: true)
                }
                var args: [QExpr] = []
                if !isOp(")") { repeat { args.append(try expr()) } while eatOp(",") }
                guard eatOp(")") else { throw QueryError(tr("缺少右括号", "Missing closing parenthesis")) }
                return .call(up, args, star: false)
            }
            return .column(s.lowercased())
        default:
            throw QueryError(tr("此处应为值或列名，实际为 \(describe(cur))", "Expected a value or column, found \(describe(cur))"))
        }
    }
}

// MARK: - execution

struct QRow {
    let t: Entry
    let p: Posting
    var balance = Inventory()
}

public let queryColumns = ["date", "year", "month", "day", "quarter", "flag", "payee", "narration", "description", "tags", "links",
                           "account", "position", "units", "number", "currency", "cost_number", "cost_currency", "price", "weight",
                           "balance", "filename", "lineno", "id"]

final class QEval {
    let L: Ledger
    var aliases: [String: QExpr] = [:]
    private var regexCache: [String: NSRegularExpression] = [:]
    init(_ L: Ledger) { self.L = L }

    func regex(_ pat: String, ci: Bool) throws -> NSRegularExpression {
        let key = (ci ? "i:" : "s:") + pat
        if let re = regexCache[key] { return re }
        guard let re = try? NSRegularExpression(pattern: pat, options: ci ? [.caseInsensitive] : []) else { throw QueryError(tr("正则表达式有误：\(pat)", "Invalid regular expression: \(pat)")) }
        regexCache[key] = re
        return re
    }

    func column(_ name: String, _ r: QRow) throws -> QValue {
        let t = r.t, p = r.p
        switch name {
        case "date": return .date(t.date)
        case "year": return .number(Double(t.date.prefix(4)) ?? 0)
        case "month": return .number(Double(t.date.dropFirst(5).prefix(2)) ?? 0)
        case "day": return .number(Double(t.date.suffix(2)) ?? 0)
        case "quarter": return .number(Double(((Int(t.date.dropFirst(5).prefix(2)) ?? 1) - 1) / 3 + 1))
        case "flag": return .string(p.flag ?? t.flag)
        case "payee": return t.payee.isEmpty ? .null : .string(t.payee)
        case "narration": return .string(t.narration)
        case "description": return .string([t.payee, t.narration].filter { !$0.isEmpty }.joined(separator: " | "))
        case "tags": return .set(t.tags)
        case "links": return .set(t.links)
        case "account": return .string(p.account)
        case "position", "units": return p.units.map { .amount($0, p.currency ?? "") } ?? .null
        case "number": return p.units.map { .number($0) } ?? .null
        case "currency": return p.currency.map { .string($0) } ?? .null
        case "cost_number": return p.cost?.number.map { .number($0) } ?? .null
        case "cost_currency": return p.cost?.currency.map { .string($0) } ?? .null
        case "price": return p.price.flatMap { pr in pr.number.map { .amount($0, pr.currency ?? "") } } ?? .null
        case "weight": return weight(p).map { .amount($0.n, $0.c) } ?? .null
        case "balance": return .inventory(r.balance)
        case "filename": return .string(t.file)
        case "lineno": return .number(Double(t.line))
        case "id": return .number(Double(t.id))
        case "other_accounts": return .set(t.postings.filter { $0 !== p }.map { $0.account })
        default:
            if let a = aliases[name] { return try eval(a, r) }
            throw QueryError(tr("未知列：\(name)。可用列：\(queryColumns.joined(separator: " "))", "Unknown column: \(name). Available: \(queryColumns.joined(separator: " "))"))
        }
    }

    func eval(_ e: QExpr, _ r: QRow) throws -> QValue {
        switch e {
        case .lit(let v): return v
        case .column(let c): return try column(c, r)
        case .unary(let op, let x):
            let v = try eval(x, r)
            if op == "NOT" { return .bool(!v.truthy) }
            return negate(v)
        case .isNull(let x, let neg):
            let v = try eval(x, r)
            return .bool((v == .null) != neg)
        case .inList(let x, let list, let neg):
            let v = try eval(x, r)
            var hit = false
            if list.count == 1, case .set(let s) = try eval(list[0], r) {
                hit = v.stringValue.map { s.contains($0) } ?? false
            } else {
                for y in list {
                    if equal(v, try eval(y, r)) { hit = true; break }
                }
            }
            return .bool(hit != neg)
        case .binary(let op, let l, let rr):
            if op == "AND" { return .bool(try eval(l, r).truthy && eval(rr, r).truthy) }
            if op == "OR" { return .bool(try eval(l, r).truthy || eval(rr, r).truthy) }
            let a = try eval(l, r), b = try eval(rr, r)
            return try binary(op, a, b)
        case .call(let n, let args, _):
            if QExpr.aggregates.contains(n) { throw QueryError(tr("\(n) 仅可用于聚合查询", "\(n) is only allowed in aggregate queries")) }
            return try scalar(n, args.map { try eval($0, r) })
        }
    }

    func negate(_ v: QValue) -> QValue {
        switch v {
        case .number(let n): return .number(-n)
        case .amount(let n, let c): return .amount(-n, c)
        case .inventory(let inv): var o = Inventory(); for (c, n) in inv.nonZero { o.add(-n, c) }; return .inventory(o)
        default: return v
        }
    }

    func equal(_ a: QValue, _ b: QValue) -> Bool {
        if let x = a.stringValue, let y = b.stringValue { return x == y }
        if case .number(let x) = a, case .number(let y) = b { return abs(x - y) < 1e-9 }
        if case .amount(let x, _) = a, case .number(let y) = b { return abs(x - y) < 1e-9 }
        return a == b
    }

    func compare(_ a: QValue, _ b: QValue) -> Int? {
        if let x = a.stringValue, let y = b.stringValue { return x < y ? -1 : x > y ? 1 : 0 }
        if let x = a.sortNumber, let y = b.sortNumber { return x < y ? -1 : x > y ? 1 : 0 }
        return nil
    }

    func binary(_ op: String, _ a: QValue, _ b: QValue) throws -> QValue {
        switch op {
        case "=": return .bool(equal(a, b))
        case "!=": return .bool(!equal(a, b))
        case "<", "<=", ">", ">=":
            guard let c = compare(a, b) else { return .bool(false) }
            switch op {
            case "<": return .bool(c < 0)
            case "<=": return .bool(c <= 0)
            case ">": return .bool(c > 0)
            default: return .bool(c >= 0)
            }
        case "~", "!~":
            let s = a.stringValue ?? a.text
            guard let pat = b.stringValue else { return .bool(false) }
            let re = try regex(pat, ci: true)
            let hit = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
            return .bool(op == "~" ? hit : !hit)
        case "+", "-", "*", "/":
            func num(_ v: QValue) -> Double? { if case .number(let n) = v { return n }; return nil }
            // date ± days
            if case .date(let d) = a, let y = num(b), op == "+" || op == "-" { return .date(Day.shift(d, op == "+" ? Int(y) : -Int(y))) }
            if let x = num(a), let y = num(b) {
                switch op {
                case "+": return .number(x + y)
                case "-": return .number(x - y)
                case "*": return .number(x * y)
                default: return y == 0 ? .null : .number(x / y)
                }
            }
            if case .amount(let x, let c) = a, let y = num(b) {
                switch op {
                case "*": return .amount(x * y, c)
                case "/": return y == 0 ? .null : .amount(x / y, c)
                case "+": return .amount(x + y, c)
                default: return .amount(x - y, c)
                }
            }
            if case .amount(let x, let c) = a, case .amount(let y, let d) = b, c == d, op == "+" || op == "-" {
                return .amount(op == "+" ? x + y : x - y, c)
            }
            if op == "+", let x = a.stringValue, let y = b.stringValue { return .string(x + y) }
            return .null
        default:
            throw QueryError(tr("不支持的运算符：\(op)", "Unsupported operator: \(op)"))
        }
    }

    func scalar(_ n: String, _ a: [QValue]) throws -> QValue {
        func arg(_ k: Int) throws -> QValue {
            guard k < a.count else { throw QueryError(tr("\(n)  参数数量不足", "\(n): not enough arguments")) }
            return a[k]
        }
        func date() throws -> String? { try arg(0).stringValue }
        switch n {
        case "YEAR": return try date().map { .number(Double($0.prefix(4)) ?? 0) } ?? .null
        case "MONTH": return try date().map { .number(Double($0.dropFirst(5).prefix(2)) ?? 0) } ?? .null
        case "DAY": return try date().map { .number(Double($0.suffix(2)) ?? 0) } ?? .null
        case "QUARTER": return try date().map { .number(Double(((Int($0.dropFirst(5).prefix(2)) ?? 1) - 1) / 3 + 1)) } ?? .null
        case "YMONTH": return try date().map { .string(String($0.prefix(7))) } ?? .null
        case "PARENT":
            guard let s = try arg(0).stringValue else { return .null }
            let p = s.components(separatedBy: ":")
            return p.count > 1 ? .string(p.dropLast().joined(separator: ":")) : .null
        case "LEAF":
            guard let s = try arg(0).stringValue else { return .null }
            return .string(leaf(s))
        case "ROOT":
            guard let s = try arg(0).stringValue else { return .null }
            let k = a.count > 1 ? Int(a[1].sortNumber ?? 1) : 1
            return .string(s.components(separatedBy: ":").prefix(max(1, k)).joined(separator: ":"))
        case "GREP":
            guard let pat = try arg(0).stringValue, let s = try arg(1).stringValue,
                  let re = try? regex(pat, ci: false),
                  let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)),
                  let rr = Range(m.range, in: s) else { return .null }
            return .string(String(s[rr]))
        case "UNITS": return try arg(0)
        case "COST":
            return try arg(0)   // positions are carried as units; cost is available as cost_number
        case "NUMBER":
            switch try arg(0) {
            case .amount(let x, _): return .number(x)
            case .number(let x): return .number(x)
            case .inventory(let i): return i.nonZero.count == 1 ? .number(i.nonZero[0].1) : .null
            default: return .null
            }
        case "CURRENCY":
            switch try arg(0) {
            case .amount(_, let c): return .string(c)
            case .inventory(let i): return i.nonZero.count == 1 ? .string(i.nonZero[0].0) : .null
            default: return .null
            }
        case "ABS":
            switch try arg(0) {
            case .number(let x): return .number(abs(x))
            case .amount(let x, let c): return .amount(abs(x), c)
            case .inventory(let inv): var o = Inventory(); for (c, x) in inv.nonZero { o.add(abs(x), c) }; return .inventory(o)
            default: return .null
            }
        case "NEG": return negate(try arg(0))
        case "POSSIGN": return try arg(0)
        case "CONVERT", "VALUE":
            let target = n == "VALUE" ? L.base : (a.count > 1 ? a[1].stringValue ?? L.base : L.base)
            let at: String? = n == "CONVERT" && a.count > 2 ? a[2].stringValue : nil
            func conv(_ x: Double, _ c: String) -> (Double, String) {
                if c == target { return (x, c) }
                guard let inBase = toCNY(L, x, c, at) else { return (x, c) }
                if target == L.base { return (inBase, target) }
                guard let rate = toCNY(L, 1, target, at), rate != 0 else { return (x, c) }
                return (inBase / rate, target)
            }
            switch try arg(0) {
            case .amount(let x, let c): let r = conv(x, c); return .amount(r.0, r.1)
            case .inventory(let inv):
                var o = Inventory()
                for (c, x) in inv.nonZero { let r = conv(x, c); o.add(r.0, r.1) }
                return .inventory(o)
            case let v: return v
            }
        case "STR": return .string(try arg(0).text)
        case "LOWER": return .string(try arg(0).text.lowercased())
        case "UPPER": return .string(try arg(0).text.uppercased())
        case "LENGTH":
            switch try arg(0) {
            case .set(let s): return .number(Double(s.count))
            case let v: return .number(Double(v.text.count))
            }
        case "COALESCE": return a.first { $0 != .null } ?? .null
        case "ONLY":
            guard case .inventory(let inv) = try arg(1), let c = try arg(0).stringValue else { return .null }
            return .amount(inv.amounts[c] ?? 0, c)
        case "TODAY": return .date(Day.today())
        default:
            throw QueryError(tr("未知函数：\(n)", "Unknown function: \(n)"))
        }
    }

    // aggregate over a group of rows
    func evalGroup(_ e: QExpr, _ rows: [QRow]) throws -> QValue {
        switch e {
        case .call(let n, let args, let star) where QExpr.aggregates.contains(n):
            switch n {
            case "COUNT":
                if star || args.isEmpty { return .number(Double(rows.count)) }
                return .number(Double(try rows.filter { try eval(args[0], $0) != .null }.count))
            case "SUM":
                guard let x = args.first else { throw QueryError(tr("SUM 需要一个参数", "SUM takes one argument")) }
                var inv = Inventory()
                var plain = 0.0, allPlain = true
                for r in rows {
                    switch try eval(x, r) {
                    case .amount(let n, let c): inv.add(n, c); allPlain = false
                    case .inventory(let i): for (c, n) in i.nonZero { inv.add(n, c) }; allPlain = false
                    case .number(let n): plain += n
                    default: break
                    }
                }
                if allPlain { return .number(plain) }
                return .inventory(inv)
            case "FIRST": return try rows.first.map { try eval(args[0], $0) } ?? .null
            case "LAST": return try rows.last.map { try eval(args[0], $0) } ?? .null
            default:
                var best: QValue = .null
                for r in rows {
                    let v = try eval(args[0], r)
                    if v == .null { continue }
                    if best == .null { best = v; continue }
                    if let c = compare(v, best), (n == "MIN" ? c < 0 : c > 0) { best = v }
                }
                return best
            }
        case .call(let n, let args, _):
            return try scalar(n, args.map { try evalGroup($0, rows) })
        case .unary(let op, let x):
            let v = try evalGroup(x, rows)
            return op == "NOT" ? .bool(!v.truthy) : negate(v)
        case .binary(let op, let l, let r):
            if op == "AND" { return .bool(try evalGroup(l, rows).truthy && evalGroup(r, rows).truthy) }
            if op == "OR" { return .bool(try evalGroup(l, rows).truthy || evalGroup(r, rows).truthy) }
            return try binary(op, try evalGroup(l, rows), try evalGroup(r, rows))
        case .column(let c):
            if let a = aliases[c] { return try evalGroup(a, rows) }
            return try rows.first.map { try eval(e, $0) } ?? .null
        default:
            return try rows.first.map { try eval(e, $0) } ?? .null
        }
    }
}

/// Run a BQL statement against the ledger.
public func runQuery(_ text: String, _ L: Ledger) throws -> QueryResult {
    let toks = try qTokenize(text)
    let p = QParser(toks)
    var st = try p.statement()
    let ev = QEval(L)
    if st.star {
        st.targets = ["date", "flag", "payee", "narration", "account", "position"].map { QTarget(expr: .column($0), alias: nil) }
    }
    for tg in st.targets { if let a = tg.alias { ev.aliases[a.lowercased()] = tg.expr } }

    // rows: every posting of every transaction (pad transactions included, like Beancount)
    var rows: [QRow] = []
    for t in L.txns {
        if let f = st.from {
            // FROM filters transactions: keep it if any posting matches
            var keep = false
            for p in t.postings {
                if try ev.eval(f, QRow(t: t, p: p)).truthy { keep = true; break }
            }
            if !keep { continue }
        }
        for p in t.postings {
            let r = QRow(t: t, p: p)
            if let w = st.whereExpr, !(try ev.eval(w, r).truthy) { continue }
            rows.append(r)
        }
    }

    // resolve "GROUP BY 1" and aliases to expressions
    func resolve(_ e: QExpr) -> QExpr {
        if case .lit(.number(let n)) = e, n >= 1, Int(n) <= st.targets.count { return st.targets[Int(n) - 1].expr }
        if case .column(let c) = e, let a = ev.aliases[c] { return a }
        return e
    }

    let aggregate = st.groupBy != nil || st.targets.contains { $0.expr.hasAggregate }
    var out: [[QValue]] = []
    var sortKeys: [[QValue]] = []
    let orders = st.orderBy.map { QOrder(expr: resolve($0.expr), desc: $0.desc) }

    if aggregate {
        let keys = st.groupBy.map { $0.map(resolve) } ?? st.targets.map { $0.expr }.filter { !$0.hasAggregate }
        var groups: [String: [QRow]] = [:]
        var order: [String] = []
        for r in rows {
            let k = try keys.map { try ev.eval($0, r).text }.joined(separator: "\u{1}")
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(r)
        }
        if keys.isEmpty && order.isEmpty { order = [""]; groups[""] = [] }
        for k in order {
            let g = groups[k]!
            out.append(try st.targets.map { try ev.evalGroup($0.expr, g) })
            sortKeys.append(try orders.map { try ev.evalGroup($0.expr, g) })
        }
    } else {
        // running balance in date order, for the "balance" column
        var running = Inventory()
        for idx in rows.indices {
            if let u = rows[idx].p.units, let c = rows[idx].p.currency { running.add(u, c) }
            rows[idx].balance = running
        }
        for r in rows {
            out.append(try st.targets.map { try ev.eval($0.expr, r) })
            sortKeys.append(try orders.map { try ev.eval($0.expr, r) })
        }
    }

    if !orders.isEmpty {
        let idx = out.indices.sorted { a, b in
            for (k, o) in orders.enumerated() {
                let x = sortKeys[a][k], y = sortKeys[b][k]
                if let c = ev.compare(x, y), c != 0 { return o.desc ? c > 0 : c < 0 }
                if x == .null && y != .null { return !o.desc }
                if y == .null && x != .null { return o.desc }
            }
            return a < b
        }
        out = idx.map { out[$0] }
    }
    if st.distinct {
        var seen = Set<String>()
        out = out.filter { seen.insert($0.map { $0.text }.joined(separator: "\u{1}")).inserted }
    }
    if let n = st.limit { out = Array(out.prefix(n)) }

    let names = st.targets.map { $0.alias ?? $0.expr.name }
    let numeric = names.indices.map { c in out.contains { r in
        switch r[c] { case .number, .amount, .inventory: return true; default: return false }
    } }
    return QueryResult(columns: names, rows: out, numeric: numeric)
}

// MARK: - saved queries

public struct SavedQuery: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var text: String
    public var source: String   // "builtin", "ledger" (query directive / .bql file) or "mine"
    public init(id: String = UUID().uuidString, name: String, text: String, source: String) {
        self.id = id; self.name = name; self.text = text; self.source = source
    }
}

/// A .bql file from named queries: "-- name", a blank line, the query; queries separated by a blank line.
public func serializeBQL(_ qs: [SavedQuery]) -> String {
    qs.map { "-- " + $0.name.replacingOccurrences(of: "\n", with: " ") + "\n\n" + $0.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" }
        .joined(separator: "\n")
}

/// "file:queries/custom.bql#2" → ("queries/custom.bql", 2)
public func bqlLocation(_ id: String) -> (path: String, index: Int)? {
    guard id.hasPrefix("file:"), let r = id.range(of: "#", options: .backwards), let i = Int(id[r.upperBound...]) else { return nil }
    return (String(id[id.index(id.startIndex, offsetBy: 5)..<r.lowerBound]), i)
}

/// Split a .bql file into queries; "-- title" comment lines name the query that follows.
public func parseBQLFile(_ text: String, file: String) -> [SavedQuery] {
    var out: [SavedQuery] = []
    var title: String? = nil
    var body: [String] = []
    func flush() {
        let b = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.isEmpty {
            let name = title ?? "\((file as NSString).lastPathComponent) #\(out.count + 1)"
            out.append(SavedQuery(id: "file:\(file)#\(out.count)", name: name, text: b, source: "ledger"))
        }
        body = []
        title = nil
    }
    for line in text.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("--") {
            let c = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !body.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { flush() }
            if !c.isEmpty { title = c }
            continue
        }
        if t.isEmpty && !body.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            continue
        }
        body.append(line)
        if t.hasSuffix(";") { flush() }
    }
    flush()
    return out
}

public let builtinQueries: [SavedQuery] = [
    SavedQuery(id: "b:balances", name: "资产余额", text: "SELECT account, SUM(position) AS balance\nWHERE account ~ \"^Assets:\"\nGROUP BY account\nORDER BY account", source: "builtin"),
    SavedQuery(id: "b:liabilities", name: "负债余额", text: "SELECT account, SUM(position) AS balance\nWHERE account ~ \"^Liabilities:\"\nGROUP BY account\nORDER BY account", source: "builtin"),
    SavedQuery(id: "b:monthly", name: "月度支出汇总", text: "SELECT year, month, SUM(CONVERT(position, 'CNY')) AS total\nWHERE account ~ \"^Expenses:\"\nGROUP BY year, month\nORDER BY year DESC, month DESC", source: "builtin"),
    SavedQuery(id: "b:category", name: "本年支出构成", text: "SELECT ROOT(account, 2) AS category, SUM(CONVERT(position, 'CNY')) AS total\nWHERE account ~ \"^Expenses:\" AND year = YEAR(TODAY())\nGROUP BY category\nORDER BY total DESC", source: "builtin"),
    SavedQuery(id: "b:payees", name: "本年商户支出排行", text: "SELECT payee, COUNT(*) AS n, SUM(CONVERT(position, 'CNY')) AS total\nWHERE account ~ \"^Expenses:\" AND year = YEAR(TODAY())\nGROUP BY payee\nORDER BY total DESC\nLIMIT 20", source: "builtin"),
    SavedQuery(id: "b:income", name: "年度收入构成", text: "SELECT year, ROOT(account, 2) AS source, SUM(NEG(CONVERT(position, 'CNY'))) AS income\nWHERE account ~ \"^Income:\"\nGROUP BY year, source\nORDER BY year DESC, income DESC", source: "builtin"),
    SavedQuery(id: "b:largest", name: "近 90 天大额支出", text: "SELECT date, payee, narration, account, position\nWHERE account ~ \"^Expenses:\" AND date >= TODAY() - 90\nORDER BY position DESC\nLIMIT 30", source: "builtin"),
    SavedQuery(id: "b:journal", name: "银行账户日记账", text: "JOURNAL \"^Assets:Bank\"", source: "builtin"),
]
