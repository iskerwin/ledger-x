import XCTest
import SwiftUI
@testable import Ledger

/// 设置 → 外观 → 金额数字: 圆体 draws the amounts in lists with rounded digits; 系统 as before
@MainActor
final class AmountDigitsTests: XCTestCase {
    private func pixels(_ rounded: Bool) throws -> [UInt8] {
        let old = AppSettings.shared.roundedAmounts
        defer { AppSettings.shared.roundedAmounts = old }
        AppSettings.shared.roundedAmounts = rounded
        let renderer = ImageRenderer(content: Amount(n: 1234567.89).font(.title).frame(width: 240, height: 40)
            .environment(\.colorScheme, .light).background(.white))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    func testRoundedDigitsAreDrawnOnlyWhenChosen() throws {
        let system = try pixels(false), again = try pixels(false), rounded = try pixels(true)
        XCTAssertEqual(system, again, "the same setting draws the same")
        XCTAssertNotEqual(system, rounded, "圆体 must change how the digits are drawn")
    }
}
