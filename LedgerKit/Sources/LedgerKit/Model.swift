import Foundation

// Swift port of ledger.js. Numbers are Doubles on purpose: results must match the
// web app (and therefore bean-check) exactly, and the web app uses JS numbers.

public let EPS = 1e-9

public enum MetaValue: Equatable {
    case string(String)
    case bool(Bool)
    case date(String)
    case number(Double)
    case amount(Double, String)
    case raw(String)

    public var display: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .date(let d): return d
        case .number(let n): return jsNumberString(n)
        case .amount(let n, let c): return jsNumberString(n) + " " + c
        case .raw(let s): return s
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// Ordered key/value metadata (insertion order is kept, later writes replace).
public struct Meta: Equatable {
    public private(set) var keys: [String] = []
    public private(set) var values: [String: MetaValue] = [:]
    public init() {}
    public subscript(key: String) -> MetaValue? {
        get { values[key] }
        set {
            if let v = newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = v
            } else if values[key] != nil {
                values[key] = nil
                keys.removeAll { $0 == key }
            }
        }
    }
    public var isEmpty: Bool { keys.isEmpty }
    public var items: [(String, MetaValue)] { keys.map { ($0, values[$0]!) } }
}

public enum EntryType: String {
    case txn, open, close, commodity, balance, pad, note, document, event, query, price, custom
}

public final class CostSpec: @unchecked Sendable {
    public var perUnit: Double?
    public var total: Double?
    public var currency: String?
    public var date: String?
    public var label: String?
    public var merge = false
    public var totalBraces: Bool
    public var raw: String
    public var number: Double?
    public var interpolated = false

    public init(totalBraces: Bool, raw: String) {
        self.totalBraces = totalBraces
        self.raw = raw
    }

    func copy() -> CostSpec {
        let c = CostSpec(totalBraces: totalBraces, raw: raw)
        c.perUnit = perUnit; c.total = total; c.currency = currency; c.date = date; c.label = label
        c.merge = merge; c.number = number; c.interpolated = interpolated
        return c
    }
}

public final class PriceSpec: @unchecked Sendable {
    public var number: Double?
    public var currency: String?
    public var total: Bool
    public var raw: Double?
    public var interpolated = false

    public init(number: Double?, currency: String?, total: Bool, raw: Double?) {
        self.number = number; self.currency = currency; self.total = total; self.raw = raw
    }
}

public struct LotCost: Equatable {
    public var number: Double
    public var currency: String?
    public var date: String?
    public var label: String?
}

public final class Lot: @unchecked Sendable {
    public var units: Double
    public var currency: String
    public var cost: LotCost?
    public init(units: Double, currency: String, cost: LotCost?) {
        self.units = units; self.currency = currency; self.cost = cost
    }
    func clone() -> Lot { Lot(units: units, currency: currency, cost: cost) }
}

public struct Booked {
    public let lot: Lot
    public let take: Double
}

public final class Posting: @unchecked Sendable {
    public var account: String
    public var flag: String?
    public var units: Double?
    public var currency: String?
    public var digits: Int?
    public var cost: CostSpec?
    public var price: PriceSpec?
    public var meta = Meta()
    public var interpolated = false
    public var booked: [Booked]?
    public var augment = false

    public init(account: String) { self.account = account }

    /// shallow copy, like `{ ...p }` in JS (cost / price objects are shared)
    func shallowCopy() -> Posting {
        let p = Posting(account: account)
        p.flag = flag; p.units = units; p.currency = currency; p.digits = digits
        p.cost = cost; p.price = price; p.meta = meta; p.interpolated = interpolated
        p.booked = booked; p.augment = augment
        return p
    }
}

public final class Entry: @unchecked Sendable {
    public let type: EntryType
    public var date: String
    public var file: String
    public var line: Int
    public var startLine: Int
    public var endLine: Int
    public var meta = Meta()
    public var src = ""
    public var seq = -1
    public var id = -1

    // transaction
    public var flag = "*"
    public var payee = ""
    public var narration = ""
    public var hasPayee = false
    public var tags: [String] = []
    public var links: [String] = []
    public var postings: [Posting] = []
    public var bad: [String] = []
    public var synthetic = false

    // other directives
    public var account: String?
    public var currencies: [String] = []
    public var booking: String?
    public var currency: String?
    public var number: Double = 0
    public var digits: Int = 0
    public var tolerance: Double?
    public var source: String?
    public var comment: String?
    public var path: String?
    public var name: String?
    public var eventDescription: String?
    public var query: String?
    public var quote: String?
    public var values: [MetaValue] = []

    public init(type: EntryType, date: String, file: String, line: Int, startLine: Int, endLine: Int) {
        self.type = type; self.date = date; self.file = file; self.line = line
        self.startLine = startLine; self.endLine = endLine
    }

    func copyBase(as type: EntryType) -> Entry {
        let e = Entry(type: type, date: date, file: file, line: line, startLine: startLine, endLine: endLine)
        e.meta = meta
        return e
    }
}

public struct LedgerError {
    public weak var entry: Entry?
    public var file: String?
    public var line: Int?
    public var msg: String
    public var soft = false

    public init(entry: Entry?, msg: String, soft: Bool = false) {
        self.entry = entry; self.file = entry?.file; self.line = entry?.line; self.msg = msg; self.soft = soft
    }
    public init(file: String?, line: Int?, msg: String) {
        self.entry = nil; self.file = file; self.line = line; self.msg = msg
    }
}

public struct Account {
    public var name: String
    public var open: String?
    public var close: String?
    public var currencies: [String] = []
    public var booking: String?
    public var meta = Meta()
    public var implicit = false
}

public struct BalanceResult {
    public let entry: Entry
    public let got: Double
    public let ok: Bool
    public let diff: Double
}

public struct RatePoint {
    public let date: String
    public let v: Double
}

public final class Ledger: @unchecked Sendable {
    public var entries: [Entry] = []
    public var files: [String] = []
    public var options: [String: [String?]] = [:]
    public var plugins: [(String?, String?)] = []
    public var errors: [LedgerError] = []
    public var accounts: [String: Account] = [:]
    public var txns: [Entry] = []
    public var balances: [Entry] = []
    public var prices: [Entry] = []
    public var commodities: [String: Meta] = [:]
    public var pads: [Entry] = []
    public var events: [Entry] = []
    public var notes: [Entry] = []
    public var documents: [Entry] = []
    public var base = "CNY"
    public var balanceResults: [BalanceResult] = []
    /// account -> currency -> units
    public var final: [String: [String: Double]] = [:]
    public var inventory: [String: [Lot]] = [:]
    public var rates: [String: [RatePoint]] = [:]

    public init() {}
}

// MARK: - JS number helpers
//
// Rounding rule used everywhere money is displayed: ties go toward +∞
// (like JS `Math.round`: 2.5 → 3, -2.5 → -2). This is NOT banker's rounding
// and NOT "away from zero" — see the pin-down tests in RoundingTests.
//
// Known divergences from real JS `String(n)` — locked in deliberately, do not
// "fix" without checking the golden tests first:
//   * 1e15 expands to "1000000000000000.0" (real JS prints plain digits up to 1e21)
//   * 1e-7 expands to "0.0000001" (real JS prints "1e-7")
//   * Infinity renders as "inf" (real JS prints "Infinity")

/// `String(n)` in JS for the values we deal with (shortest round-trip, no exponent for normal ranges).
public func jsNumberString(_ n: Double) -> String {
    if n.isNaN { return "NaN" }
    if n == n.rounded() && abs(n) < 1e15 { return String(Int64(n)) }
    var s = "\(n)"
    if s.contains("e") {
        // expand small exponents (JS uses fixed notation down to 1e-7)
        for d in 1...20 {
            let f = String(format: "%.\(d)f", n)
            if Double(f) == n { s = f; break }
        }
    }
    return s
}

/// JS `Number.prototype.toFixed(d)`.
/// Exact binary ties (.5 representable) round away from zero (printf rounds
/// them to even, hence the manual correction below). "-0.00" is stripped to
/// "0.00" — real JS keeps the minus sign; locked in here deliberately.
public func toFixed(_ n: Double, _ d: Int) -> String {
    var s = String(format: "%.\(d)f", n)
    // JS rounds exact ties away from zero (printf rounds them to even)
    if d < 17 {
        let scaled = abs(n) * pow(10, Double(d))
        if scaled < 1e15, scaled - scaled.rounded(.down) == 0.5 {
            let up = (scaled.rounded(.down) + 1) / pow(10, Double(d))
            s = String(format: "%.\(d)f", n < 0 ? -up : up)
        }
    }
    if s.hasPrefix("-"), Double(s) == 0 { s.removeFirst() }
    return s
}

/// JS `Math.round`: ties go toward +∞. jsRound(2.5) == 3, jsRound(-2.5) == -2.
/// (Differs from "round half away from zero" only for negative ties.)
@inline(__always) func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

public func roundTo(_ n: Double, _ d: Int) -> Double {
    let f = pow(10.0, Double(d))
    return jsRound(n * f) / f
}

@inline(__always) func sign(_ x: Double) -> Double { x > 0 ? 1 : x < 0 ? -1 : 0 }
