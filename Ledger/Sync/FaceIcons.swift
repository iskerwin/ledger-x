import UIKit
import CryptoKit
import LedgerKit

/// The icons put on card faces (编辑卡面 → 水印 → 图标): small PNGs in a folder of the ledger's own on this phone,
/// never in the ledger or its files. The silhouette drawn in the card's ink is made from them when shown.
@MainActor
enum FaceIcons {
    /// the longest side an icon is kept at: a watermark is never drawn larger than this
    static let side: CGFloat = 256
    private static var cache: [String: UIImage] = [:]

    private static func folder(ledger: String) throws -> URL {
        let key = SHA256.hash(data: Data(ledger.utf8)).map { String(format: "%02x", $0) }.joined()
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("CardIcons", isDirectory: true).appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// keep a picked image, shrunk to `side`: its file name, nil when it is not an image
    static func save(_ data: Data, ledger: String) -> String? {
        guard let picked = UIImage(data: data), picked.size.width > 0, picked.size.height > 0 else { return nil }
        let scale = min(1, side / max(picked.size.width, picked.size.height))
        let size = CGSize(width: (picked.size.width * scale).rounded(), height: (picked.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in picked.draw(in: CGRect(origin: .zero, size: size)) }
        guard let png = small.pngData() else { return nil }
        let name = UUID().uuidString + ".png"
        guard let dir = try? folder(ledger: ledger),
              (try? png.write(to: dir.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
        else { return nil }
        return name
    }

    static func remove(_ name: String, ledger: String) {
        guard let dir = try? folder(ledger: ledger) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        cache = cache.filter { !$0.key.hasPrefix(ledger + "|" + name + "|") }
    }

    static func removeAll(ledger: String) {
        guard let dir = try? folder(ledger: ledger) else { return }
        try? FileManager.default.removeItem(at: dir)
        cache = cache.filter { !$0.key.hasPrefix(ledger + "|") }
    }

    /// the icon as drawn: in its own colours, or (`mono`) as a shape to be filled with the card's ink
    static func image(_ name: String, ledger: String, mono: Bool, strength: Double) -> UIImage? {
        let key = ledger + "|" + name + "|" + (mono ? String(format: "%.2f", strength) : "colour")
        if let hit = cache[key] { return hit }
        guard let dir = try? folder(ledger: ledger), let original = UIImage(contentsOfFile: dir.appendingPathComponent(name).path) else { return nil }
        let made = mono ? shape(original, strength: strength) : original
        if let made { cache[key] = made }
        return made
    }

    /// white with the silhouette's alpha: drawn as a template it takes the card's ink
    private static func shape(_ image: UIImage, strength: Double) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let read = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard read else { return nil }
        let alpha = silhouette(rgba: rgba, width: w, height: h, strength: strength)
        guard alpha.count == w * h else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let a = alpha[i]
            // premultiplied white
            out[i * 4] = a; out[i * 4 + 1] = a; out[i * 4 + 2] = a; out[i * 4 + 3] = a
        }
        let made = out.withUnsafeMutableBytes { buf -> CGImage? in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info)?.makeImage()
        }
        return made.map { UIImage(cgImage: $0).withRenderingMode(.alwaysTemplate) }
    }
}
