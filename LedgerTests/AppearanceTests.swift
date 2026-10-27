import XCTest
import SwiftUI
@testable import Ledger
@testable import LedgerKit

@MainActor
final class AppearanceTests: XCTestCase {
    func testThemeInkAndFinancialColorsStayReadableOnStandardSurfaces() {
        let previous = AppSettings.shared.theme
        defer { AppSettings.shared.theme = previous }
        for theme in AppTheme.allCases {
            AppSettings.shared.theme = theme.rawValue
            for scheme in [ColorScheme.light, .dark] {
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                for background in [UIColor.systemBackground, .systemGroupedBackground, .secondarySystemGroupedBackground] {
                    for ink in [Color.jadeInk, .gain, .loss, .warn] {
                        XCTAssertGreaterThanOrEqual(contrast(ink.resolve(in: environment), Color(uiColor: background).resolve(in: environment)),
                                                   4.5, "\(theme) \(scheme)")
                    }
                }
            }
        }
    }

    func testFilledThemeTextIsReadableInBothAppearances() {
        for theme in AppTheme.allCases {
            for scheme in [ColorScheme.light, .dark] {
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                let ink = theme.onColor.resolve(in: environment)
                let fill = theme.color.resolve(in: environment)
                XCTAssertGreaterThanOrEqual(contrast(ink, fill), 4.5, "\(theme) \(scheme)")
            }
        }
    }

    func testBadgeUsesReadableForegroundOnItsActualFill() throws {
        for theme in AppTheme.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let image = try render(IconBadge(symbol: "square.fill", color: theme.color, size: 40)
                    .environment(\.colorScheme, scheme).frame(width: 40, height: 40))
                let pixels = rgba(image)
                let center = luminance(pixels, pixel: 20 * image.width + 20)
                let background = luminance(pixels, pixel: 20 * image.width + 4)
                XCTAssertGreaterThanOrEqual((max(center, background) + 0.05) / (min(center, background) + 0.05),
                                           4.5, "\(theme) \(scheme)")
            }
        }
    }

    func testRawQueryNumbersAndAmountsDoNotImplyProfitOrLoss() throws {
        let hidden = KitPrivacy.masked
        KitPrivacy.masked = false
        defer { KitPrivacy.masked = hidden }
        for value in [QValue.number(-120), .amount(-120, "CNY"), .number(120)] {
            let result = QueryResult(columns: ["balance"], rows: [[value]], numeric: [true])
            // Render the production cell itself: ImageRenderer cannot render a UIKit-backed ScrollView.
            let image = try render(ResultTable(result: result).cell(value, numeric: true).frame(width: 300, height: 100)
                .environment(\.colorScheme, .light).background(.white))
            let pixels = rgba(image)
            let coloured = stride(from: 0, to: pixels.count, by: 4).filter { i in
                Int(max(pixels[i], pixels[i + 1], pixels[i + 2])) - Int(min(pixels[i], pixels[i + 1], pixels[i + 2])) > 40
            }.count
            XCTAssertEqual(coloured, 0, "Raw query \(value) should keep its sign, without a financial verdict")
            XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).contains {
                min(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) < 200 && pixels[$0 + 3] > 0
            }, "The table must actually render")
        }
    }

    private func render<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func luminance(_ bytes: [UInt8], pixel: Int) -> Double {
        let i = pixel * 4
        return luminance(Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255)
    }

    private func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ a: Color.Resolved, _ b: Color.Resolved) -> Double {
        let x = luminance(Double(a.red), Double(a.green), Double(a.blue))
        let y = luminance(Double(b.red), Double(b.green), Double(b.blue))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
