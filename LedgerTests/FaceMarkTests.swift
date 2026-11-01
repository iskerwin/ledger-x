import XCTest
import SwiftUI
@testable import Ledger

/// A built-in institution icon is a watermark: drawn in the card's ink as faint as 透明度 sets, never solid.
@MainActor
final class FaceMarkTests: XCTestCase {
    /// the brightest pixel of a card's watermark drawn alone on black, 0…255
    private func brightest(opacity: Double) throws -> Int {
        var style = FaceStyle()
        style.mark = .symbol("hsbc")
        style.opacity = opacity
        let design = FaceDesign(account: "Assets:Bank:HSBC", title: "HSBC", tint: .blue, style: style, ledger: "test")
        XCTAssertNotNil(design.symbol, "HSBC has a built-in icon")
        let renderer = ImageRenderer(content: Canvas { context, size in design.drawMark(in: &context, size: size) }
            .frame(width: 320, height: 180).background(.black))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: bytes.count, by: 4).map { Int(max(bytes[$0], bytes[$0 + 1], bytes[$0 + 2])) }.max() ?? 0
    }

    func testABuiltInIconIsAsFaintAsTheOpacitySet() throws {
        let faint = try brightest(opacity: 0.12), stronger = try brightest(opacity: 0.36)
        XCTAssertGreaterThan(faint, 0, "the icon is drawn")
        // white ink at 12%: about 31 on black, never the solid white of the ink itself
        XCTAssertLessThan(faint, 60, "drawn at 透明度, not solid")
        XCTAssertGreaterThan(stronger, faint + 30, "a higher 透明度 draws it stronger")
        XCTAssertLessThan(stronger, 130)
    }
}
