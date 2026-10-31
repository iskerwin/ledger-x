import XCTest
import SwiftUI
@testable import Ledger
@testable import LedgerKit

@MainActor
final class AppearanceTests: XCTestCase {
    func testMultiCurrencyFlowLegendUsesTheSameIncomeAndExpenseColorsAsItsBars() throws {
        let old = AppSettings.shared.theme
        AppSettings.shared.theme = AppTheme.blue.rawValue
        defer { AppSettings.shared.theme = old }
        var flow = MonthFlow()
        flow.income.add(100, "CNY"); flow.income.add(80, "USD")
        flow.expenses.add(60, "CNY"); flow.expenses.add(30, "USD")
        let image = try render(FlowCharts(months: ["2026-10"], flows: ["2026-10": flow], base: "CNY", picked: .constant(nil))
            .frame(width: 330).environment(\.colorScheme, .light).background(.white))
        let pixels = rgba(image)
        var green = 0, red = 0
        // The shared legend is above the currency headings and bars, so bar pixels cannot hide a wrong legend.
        for y in 0..<min(20, image.height) {
            for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if g > r + 25 && g > b + 10 { green += 1 }
                if r > g + 40 && r > b + 40 { red += 1 }
            }
        }
        XCTAssertGreaterThan(green, 5)
        XCTAssertGreaterThan(red, 5, "The expense legend must be red even with a blue theme")
    }

    func testForecastMarksRiskWithoutTurningTheWholeTrendIntoAnError() throws {
        let old = AppSettings.shared.theme
        AppSettings.shared.theme = AppTheme.blue.rawValue
        defer { AppSettings.shared.theme = old }
        let points = [ForecastPoint(date: "2026-10-01", value: 100), ForecastPoint(date: "2026-10-02", value: -20),
                      ForecastPoint(date: "2026-10-03", value: 60)]
        let image = try render(Sparkline(points: points, warn: true).frame(width: 180, height: 70)
            .environment(\.colorScheme, .light).background(.white))
        let pixels = rgba(image)
        var blue = 0, red = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            if b > g + 30 && g > r + 20 { blue += 1 }
            if r > g + 40 && r > b + 40 { red += 1 }
        }
        XCTAssertGreaterThan(blue, 20, "The trend remains in the theme colour")
        XCTAssertGreaterThan(red, 5, "A negative low point must remain visible as a risk")
    }

    func testThemeInkAndFinancialColorsStayReadableOnStandardSurfaces() {
        let previous = AppSettings.shared.theme
        defer { AppSettings.shared.theme = previous }
        for theme in AppTheme.allCases {
            AppSettings.shared.theme = theme.rawValue
            for scheme in [ColorScheme.light, .dark] {
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                for background in [UIColor.systemBackground, .systemGroupedBackground, .secondarySystemGroupedBackground] {
                    let inks = [Color.jadeInk, .gain, .loss, .warn] + ["CNY", "HKD", "USD", "EUR", "GBP", "MOP", "SGD", "JPY"].map(currencyColor)
                    for ink in inks {
                        let resolved = ink.resolve(in: environment), surface = Color(uiColor: background).resolve(in: environment)
                        XCTAssertGreaterThanOrEqual(contrast(resolved, surface),
                                                   4.5, "\(theme) \(scheme)")
                        let soft = Color(red: Double(resolved.red * 0.14 + surface.red * 0.86),
                                         green: Double(resolved.green * 0.14 + surface.green * 0.86),
                                         blue: Double(resolved.blue * 0.14 + surface.blue * 0.86))
                        XCTAssertGreaterThanOrEqual(contrast(resolved, soft.resolve(in: environment)), 4.5,
                                                   "Soft notice \(theme) \(scheme)")
                    }
                }
            }
        }
    }

    func testRemovedThemesMoveToTheNearestOneStillOffered() {
        // red, green and orange were the colours of money out, money in and warnings; yellow was unreadable as text
        XCTAssertEqual(AppTheme.migrated("red"), AppTheme.plum.rawValue)
        XCTAssertEqual(AppTheme.migrated("pink"), AppTheme.plum.rawValue)
        for raw in ["orange", "yellow", "green", "mint", "teal", "nonsense"] {
            XCTAssertEqual(AppTheme.migrated(raw), AppTheme.jade.rawValue, raw)
        }
        for theme in AppTheme.allCases { XCTAssertEqual(AppTheme.migrated(theme.rawValue), theme.rawValue) }
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
            // A plain loop: chaining filter/contains on stride makes Xcode 26.6 give up type-checking.
            var coloured = 0
            var drawn = false
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if max(r, g, b) - min(r, g, b) > 40 { coloured += 1 }
                if min(r, g, b) < 200 && pixels[i + 3] > 0 { drawn = true }
            }
            XCTAssertEqual(coloured, 0, "Raw query \(value) should keep its sign, without a financial verdict")
            XCTAssertTrue(drawn, "The table must actually render")
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
