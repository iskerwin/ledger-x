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
