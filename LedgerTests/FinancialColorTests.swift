import XCTest
import SwiftUI
@testable import Ledger

/// Money in green, money out red, in every theme; a change green when it is better, red when worse, grey when flat.
@MainActor
final class FinancialColorTests: XCTestCase {
    func testMoneyInAndOutKeepTheirColoursInEveryTheme() {
        let old = AppSettings.shared.theme
        defer { AppSettings.shared.theme = old }
        for theme in AppTheme.allCases {
            AppSettings.shared.theme = theme.rawValue
            for scheme in [ColorScheme.light, .dark] {
                assertColor(Amount(n: 12, color: true).tint, Color(uiColor: .systemGreen).readableInk, scheme)
                // spending used to be drawn in the plain text colour
                assertColor(Amount(n: -12, color: true).tint, Color(uiColor: .systemRed).readableInk, scheme)
                assertColor(JournalCalendar.spend, Color(uiColor: .systemRed).readableInk, scheme)
                assertColor(JournalCalendar.earn, Color(uiColor: .systemGreen).readableInk, scheme)
            }
        }
    }

    /// the overview's cover keeps the chosen hue and its small white text readable, in every theme, light and dark
    func testTheCoverIsDarkEnoughForItsWhiteTextInEveryTheme() {
        let old = AppSettings.shared.theme
        defer { AppSettings.shared.theme = old }
        for theme in AppTheme.allCases {
            AppSettings.shared.theme = theme.rawValue
            for style in [UIUserInterfaceStyle.light, .dark] {
                let fill = UIColor(Color.cover).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                fill.getRed(&r, green: &g, blue: &b, alpha: &a)
                func linear(_ c: CGFloat) -> Double { c <= 0.03928 ? Double(c) / 12.92 : pow((Double(c) + 0.055) / 1.055, 2.4) }
                let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
                XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 6.39, "\(theme) \(style.rawValue)")
                XCTAssertGreaterThan(r + g + b, 0.1, "\(theme) must not go black")
            }
        }
    }

    func testAmountsWithoutColourAndZeroStayNeutral() {
        assertColor(Amount(n: 0, color: true).tint, .secondary)
        assertColor(Amount(n: -12).tint, .primary)
        assertColor(Amount(n: 12).tint, .primary)
    }

    func testChangesAreGreenWhenBetterRedWhenWorseGreyWhenFlat() {
        assertColor(.change(30), .gain)
        assertColor(.change(-30), .loss)
        assertColor(.change(0), .secondary)
        assertColor(.change(0.004), .secondary)
        // spending: more is worse
        assertColor(.change(30, upIsWorse: true), .loss)
        assertColor(.change(-30, upIsWorse: true), .gain)
        assertColor(.change(0, upIsWorse: true), .secondary)
        assertColor(.change(0.4, tolerance: 0.5), .secondary)
    }

    private func assertColor(_ actual: Color, _ expected: Color, _ scheme: ColorScheme = .light,
                             file: StaticString = #filePath, line: UInt = #line) {
        var env = EnvironmentValues()
        env.colorScheme = scheme
        let a = actual.resolve(in: env), b = expected.resolve(in: env)
        XCTAssertEqual(a.red, b.red, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.green, b.green, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.blue, b.blue, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.opacity, b.opacity, accuracy: 0.001, file: file, line: line)
    }
}
