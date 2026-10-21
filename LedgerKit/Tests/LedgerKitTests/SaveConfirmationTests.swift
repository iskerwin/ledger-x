import XCTest
@testable import LedgerKit

final class SaveConfirmationTests: XCTestCase {
    func testBalanceLineIsPartOfTheFirstText() {
        let text = saveConfirmation("已入账 · 待同步", balance: "余额：现金 12.00 CNY")
        XCTAssertEqual(text, "已入账 · 待同步\n余额：现金 12.00 CNY")
        XCTAssertEqual(saveConfirmation("已更新", balance: nil), "已更新")
        XCTAssertEqual(saveConfirmation("已更新", balance: ""), "已更新")
    }
}
