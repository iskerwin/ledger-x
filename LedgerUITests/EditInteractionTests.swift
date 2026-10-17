import XCTest

final class EditInteractionTests: XCTestCase {
    private func launch(tab: String = "add", filled: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": tab, "LEDGER_LANG": "zh"]
        if filled { app.launchEnvironment["LEDGER_FILL"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        return app
    }

    func testCloseProtectsChangesAndContinueKeepsForm() {
        let app = launch()
        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        close.tap()
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5))
        app.buttons["继续编辑"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        app.buttons["放弃修改并关闭"].tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }

    func testKeptNewDraftCanBeReopened() {
        let app = launch()
        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        close.tap()
        app.buttons["保留草稿并关闭"].tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        app.tabBars.buttons["记一笔"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.buttons["保留草稿并关闭"].waitForExistence(timeout: 5))
    }

    func testSwipeToDismissOffersTheSameUnsavedChangesChoices() {
        let app = launch()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 20))
        let bar = app.navigationBars.firstMatch
        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.15, thenDragTo: end)
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5))
        app.buttons["继续编辑"].tap()
        XCTAssertTrue(app.buttons["关闭"].exists)
    }

    func testUntouchedFormClosesWithoutPrompt() {
        let app = launch(filled: false)
        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["放弃修改并关闭"].exists)
    }
}
