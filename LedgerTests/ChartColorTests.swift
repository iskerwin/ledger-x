import XCTest
import SwiftUI
@testable import Ledger

@MainActor
final class ChartColorTests: XCTestCase {
    func testCategoryColorsKeepTheirIdentityAcrossRanksAndThemes() {
        let before = DonutSlice.make([
            (id: "Expenses:Food", label: "Food", value: 90),
            (id: "Expenses:Travel", label: "Travel", value: 60),
            (id: "Expenses:Home", label: "Home", value: 30),
        ])
        let old = AppSettings.shared.theme
        defer { AppSettings.shared.theme = old }
        for theme in AppTheme.allCases {
            AppSettings.shared.theme = theme.rawValue
            let after = DonutSlice.make([
                (id: "Expenses:Home", label: "家居", value: 120),
                (id: "Expenses:Food", label: "餐饮", value: 40),
                (id: "Expenses:Travel", label: "旅行", value: 5),
            ])
            for scheme in [ColorScheme.light, .dark] {
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                for a in before {
                    let b = after.first { $0.id == a.id }!
                    XCTAssertEqual(a.color.resolve(in: environment), b.color.resolve(in: environment), "\(a.id) \(theme)")
                }
            }
        }
    }

    func testOtherRemainsNeutralAndDoesNotChangeTheTotals() {
        let items = (1...10).map { (id: "category\($0)", label: "Category \($0)", value: Double($0)) }
        let slices = DonutSlice.make(items, top: 5)
        XCTAssertEqual(slices.reduce(0) { $0 + $1.value }, 55)
        let other = slices.first { $0.id == DonutSlice.otherID }
        XCTAssertEqual(other?.value, 15)
        XCTAssertEqual(other?.color, Color(.systemGray3))
    }
}
