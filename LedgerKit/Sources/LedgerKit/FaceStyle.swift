import Foundation

/// One account's card face as changed by hand (长按卡面 → 编辑卡面), kept on this phone per ledger. Every field left
/// nil is the automatic choice, so an empty style is the card as it was before any change.
public struct FaceStyle: Codable, Equatable {
    /// nil: recognised from the account's name; `FaceStyle.noInstitution`: none, the group's colour; else an
    /// `Institution` id
    public var institution: String?
    /// an icon colour's name (`IconTint`), nil: the institution's or the group's
    public var color: String?
    /// nil: the institution's or the one picked from the account's name; else a `FacePatternKind`
    public var pattern: String?
    public var mark: Mark?
    /// the uploaded icon's file name, in this ledger's folder on this phone
    public var icon: String?
    /// draw the icon in the card's ink (true, the default) or in its own colours
    public var iconMono: Bool?
    /// for an icon without a transparent background: how far from the corner colour still counts as background
    public var strength: Double?
    /// the watermark's size against the default one, 0.5…1.5
    public var size: Double?
    public var opacity: Double?

    public enum Mark: Codable, Equatable {
        case text(String)
        case icon
        case off
    }

    public static let noInstitution = "none"
    public static let defaultStrength = 0.3
    public static let defaultOpacity = 0.12

    public init() {}

    public var isEmpty: Bool { self == FaceStyle() }
}

public enum FacePatternKind: String, CaseIterable {
    case stripes, rings, dots, grid, none
}

/// the styles with an account renamed or merged into another (its sub-accounts too); one already kept under the
/// new name stays
public func renamedFaceStyles(_ styles: [String: FaceStyle], from: String, to: String) -> [String: FaceStyle] {
    func move(_ a: String) -> String { a == from ? to : a.hasPrefix(from + ":") ? to + String(a.dropFirst(from.count)) : a }
    var out: [String: FaceStyle] = [:]
    for (k, v) in styles where move(k) == k { out[k] = v }
    for (k, v) in styles where move(k) != k && out[move(k)] == nil { out[move(k)] = v }
    return out
}

/// An icon turned into a silhouette for the card: the alpha of each pixel of an RGBA image (8 bits each, row by
/// row). An image that has a transparent background keeps its own alpha. One without has its background taken
/// from the four corners: a pixel as close to that colour as `strength` (0…1) allows is background, a little
/// beyond it fades in, and the rest is the shape.
public func silhouette(rgba: [UInt8], width: Int, height: Int, strength: Double) -> [UInt8] {
    let n = width * height
    guard width > 0, height > 0, rgba.count >= n * 4 else { return [] }
    func px(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }
    let corners = [px(0, 0), px(width - 1, 0), px(0, height - 1), px(width - 1, height - 1)]
    if corners.contains(where: { rgba[$0 + 3] < 250 }) {
        return (0..<n).map { rgba[$0 * 4 + 3] }
    }
    let bg = (0..<3).map { c in corners.map { Double(rgba[$0 + c]) }.reduce(0, +) / 4 }
    // distance in 0…1 over the three channels; strength 0 still lifts the exact corner colour
    let cut = max(0.02, min(1, strength)) * 0.6
    let soft = 0.08
    return (0..<n).map { i in
        let o = i * 4
        let d = sqrt((0..<3).map { c in pow((Double(rgba[o + c]) - bg[c]) / 255, 2) }.reduce(0, +) / 3)
        let a = d <= cut ? 0 : d >= cut + soft ? 1 : (d - cut) / soft
        return UInt8((a * Double(rgba[o + 3])).rounded())
    }
}
