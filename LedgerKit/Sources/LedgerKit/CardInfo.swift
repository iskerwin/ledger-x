import Foundation

/// 长按卡面 → 卡片信息: a bank or credit card's number, expiry, security code and holder, kept in this phone's
/// keychain per ledger and never written to the ledger. Every field may be left empty.
public struct CardInfo: Codable, Equatable {
    /// digits only
    public var number: String
    /// MM/YY, or empty
    public var expiry: String
    public var cvv: String
    public var holder: String

    public init(number: String = "", expiry: String = "", cvv: String = "", holder: String = "") {
        self.number = number; self.expiry = expiry; self.cvv = cvv; self.holder = holder
    }

    public var isEmpty: Bool { number.isEmpty && expiry.isEmpty && cvv.isEmpty && holder.isEmpty }

    /// the last four digits, for the card's face when the ledger's own settings give none
    public var last4: String? { number.count >= 12 ? String(number.suffix(4)) : nil }
}

/// what a card number is typed as, digits only (spaces and dashes dropped), at most 19
public func cardDigits(_ s: String) -> String { String(s.filter(\.isASCII).filter(\.isNumber).prefix(19)) }

/// 4111 1111 1111 1111; an American Express number (15 digits, 34 / 37) as 3782 822463 10005
public func groupedCardNumber(_ digits: String) -> String {
    let d = Array(digits)
    let sizes = d.count == 15 && (digits.hasPrefix("34") || digits.hasPrefix("37")) ? [4, 6, 5] : Array(repeating: 4, count: 5)
    var out: [String] = [], i = 0
    for n in sizes where i < d.count {
        out.append(String(d[i..<min(d.count, i + n)])); i += n
    }
    return out.joined(separator: " ")
}

/// the number's check digit is right (Luhn), at 12 to 19 digits
public func cardNumberValid(_ digits: String) -> Bool {
    guard (12...19).contains(digits.count), digits.allSatisfy(\.isNumber) else { return false }
    var sum = 0
    for (i, c) in digits.reversed().enumerated() {
        var v = Int(String(c)) ?? 0
        if i % 2 == 1 { v *= 2; if v > 9 { v -= 9 } }
        sum += v
    }
    return sum % 10 == 0
}

/// an expiry as typed (0628, 06/28, 6/28, 06/2028) as MM/YY; nil when it is not a month of a year
public func normalizedExpiry(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let parts: [String]
    if t.contains("/") {
        parts = t.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    } else {
        guard t.count == 4 || t.count == 6 else { return nil }
        parts = [String(t.prefix(2)), String(t.dropFirst(2))]
    }
    guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
          let m = Int(parts[0]), (1...12).contains(m), parts[0].count <= 2,
          parts[1].count == 2 || (parts[1].count == 4 && parts[1].hasPrefix("20")) else { return nil }
    return String(format: "%02d/%@", m, String(parts[1].suffix(2)))
}

/// a security code is 3 or 4 digits
public func cvvValid(_ s: String) -> Bool { (3...4).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber } }

/// the cards with an account renamed or merged into another (its sub-accounts too); one already kept under the
/// new name stays
public func renamedCardInfos(_ infos: [String: CardInfo], from: String, to: String) -> [String: CardInfo] {
    func move(_ a: String) -> String { a == from ? to : a.hasPrefix(from + ":") ? to + String(a.dropFirst(from.count)) : a }
    var out: [String: CardInfo] = [:]
    for (k, v) in infos where move(k) == k { out[k] = v }
    for (k, v) in infos where move(k) != k && out[move(k)] == nil { out[move(k)] = v }
    return out
}

