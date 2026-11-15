import XCTest
@testable import LedgerKit

/// the interface text both apps show: arguments put in, in order or as a translation reorders them
final class KitStringsTests: XCTestCase {
    func testArgumentsGoInInOrder() {
        XCTAssertEqual(KitStrings.text("%@ 年 %@ 月", [2026, 3], english: false), "2026 年 3 月")
        XCTAssertEqual(KitStrings.text("没有错误", [], english: false), "没有错误")
    }

    func testAKeyWithoutEnglishStaysAsItIs() {
        XCTAssertEqual(KitStrings.text("不存在的文字 %@", ["x"], english: true), "不存在的文字 x")
    }

    func testGroupNamesFollowTheLanguage() {
        let chinese = KitLocale.chinese
        defer { KitLocale.chinese = chinese }
        KitLocale.chinese = true
        XCTAssertEqual(groupName("CreditCard"), "信用卡")
        KitLocale.chinese = false
        XCTAssertEqual(groupName("CreditCard"), "Credit Cards")
        XCTAssertEqual(groupName("Food"), "Food")
    }
}
