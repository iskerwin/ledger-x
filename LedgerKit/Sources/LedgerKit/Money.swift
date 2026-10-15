import Foundation

// MARK: - decimal arithmetic for amounts that are written down
//
// Amounts are held as Double. A Double read from "1.005" prints back as "1.005" but is really 1.00499…, so
// rounding it directly gives 1.00, and 3 × 1.115 comes to 3.3449999…. Where an amount is worked out and then
// written into the ledger (a conversion, a split, the total of a payslip, an amount Beancount would fill in),
// it is worked out on the decimal numbers instead, with the rounding rule stated.

public enum MoneyRounding {
    /// 四舍五入: halves away from zero (2.675 → 2.68, -2.675 → -2.68), for amounts the app works out
    case halfUp
    /// halves to the even digit (2.675 → 2.68, 2.665 → 2.66), what Beancount does when it fills in an amount
    case halfEven
}

/// "12.50" → 12.50, built from its digits (fast, and exact for up to 19 significant digits)
func decimalLiteral(_ s: String) -> Decimal? {
    var mantissa: UInt64 = 0, scale: Int16 = 0, digits = 0, seenDot = false
    for u in s.unicodeScalars {
        if u == "." { if seenDot { return nil }; seenDot = true; continue }
        guard let d = UInt64(exactly: u.value), d >= 48, d <= 57 else { return nil }
        digits += 1
        if digits > 19 { return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) }
        mantissa = mantissa * 10 + (d - 48)
        if seenDot { scale += 1 }
    }
    guard digits > 0 else { return nil }
    return Decimal(sign: .plus, exponent: -Int(scale), significand: Decimal(mantissa))
}

/// the decimal number a Double stands for: the shortest form that reads back as it ("1.005", not 1.00499…)
public func decimalOf(_ x: Double) -> Decimal {
    Decimal(string: "\(x)", locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(x)
}

public func rounded(_ x: Decimal, _ places: Int, _ mode: MoneyRounding = .halfUp) -> Decimal {
    var a = x, r = Decimal()
    NSDecimalRound(&r, &a, places, mode == .halfEven ? .bankers : .plain)
    return r
}

func doubleOf(_ x: Decimal) -> Double { Double(x.description) ?? NSDecimalNumber(decimal: x).doubleValue }

/// `x` rounded to `places` decimals, on its decimal value
public func roundMoney(_ x: Double, _ places: Int = 2, _ mode: MoneyRounding = .halfUp) -> Double {
    doubleOf(rounded(decimalOf(x), places, mode))
}

/// a × b, worked out on the decimal numbers and rounded
public func mulMoney(_ a: Double, _ b: Double, _ places: Int = 2, _ mode: MoneyRounding = .halfUp) -> Double {
    doubleOf(rounded(decimalOf(a) * decimalOf(b), places, mode))
}

/// a ÷ b, worked out on the decimal numbers and rounded (nil when b is 0)
public func divMoney(_ a: Double, _ b: Double, _ places: Int, _ mode: MoneyRounding = .halfUp) -> Double? {
    guard b != 0 else { return nil }
    return doubleOf(rounded(decimalOf(a) / decimalOf(b), places, mode))
}

/// `x` written with exactly `places` decimals ("6.70", "-0.50", "1200.00"); never "-0.00"
public func moneyText(_ x: Decimal, _ places: Int, _ mode: MoneyRounding = .halfUp) -> String {
    let r = rounded(x, places, mode)
    let neg = r < 0
    var s = (neg ? -r : r).description
    if places > 0 {
        if !s.contains(".") { s += "." }
        let have = s.count - 1 - s.distance(from: s.startIndex, to: s.firstIndex(of: ".")!)
        if have < places { s += String(repeating: "0", count: places - have) }
    }
    return (neg && !r.isZero ? "-" : "") + s
}

public func moneyText(_ x: Double, _ places: Int = 2, _ mode: MoneyRounding = .halfUp) -> String {
    moneyText(decimalOf(x), places, mode)
}
