import Foundation

/// Calendar decoration intensity, relative to the largest amount in the displayed month.
/// Exact one-third/two-thirds boundaries belong to the lower band; positive amounts always have a dot.
public func markLevel(amount: Double, max maximum: Double) -> Int {
    guard amount.isFinite, maximum.isFinite, amount > 0, maximum > 0 else { return 0 }
    let intensity = pow(min(amount / maximum, 1), 0.7)
    if intensity <= 1.0 / 3 { return 1 }
    if intensity <= 2.0 / 3 { return 2 }
    return 3
}
