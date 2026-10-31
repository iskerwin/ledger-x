import XCTest
import UIKit

final class ColorInteractionTests: XCTestCase {
    func testHeldSyncKeepsItsExplanationInDarkPlumTheme() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": "overview", "LEDGER_LANG": "zh",
                                 "LEDGER_THEME": "plum", "LEDGER_SYNC": "1", "LEDGER_HELD": "1"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-ledger.appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.staticTexts["已保存到本机"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["暂存本机"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "没通过提交前检查")).firstMatch.exists)
        capture(app, name: "同步-暂存说明-梅主题深色")
    }

    func testBlueThemeChartKeepsSelectionAndModeLayout() {
        checkOverview(theme: "blue", appearance: "light")
    }

    func testPlumThemeChartAtLargestTextInDarkMode() {
        checkOverview(theme: "plum", appearance: "dark", large: true)
    }

    /// Also run on the dedicated iPhone SE: chart selection and the figures stay in place on a narrow screen.
    func testPurpleThemeChartOnNarrowScreen() {
        checkOverview(theme: "purple", appearance: "light")
    }

    private func checkOverview(theme: String, appearance: String, large: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": "overview", "LEDGER_LANG": "zh", "LEDGER_THEME": theme]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-ledger.appearance", appearance]
            + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
        app.launch()
        let month = app.buttons["月"].firstMatch
        XCTAssertTrue(month.waitForExistence(timeout: 20))
        month.tap()
        let chart = app.otherElements["overview.trend"]
        // List creates off-screen rows lazily, especially when the summary grows at the largest text size.
        for _ in 0..<10 where !chart.exists { scroll(app, up: true) }
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        for _ in 0..<10 {
            let frame = chart.frame, screen = app.windows.firstMatch.frame
            if frame.minY >= 180 && frame.maxY <= screen.maxY - 100 { break }
            scroll(app, up: frame.maxY > screen.maxY - 100)
        }
        XCTAssertTrue(chart.isHittable)
        let mode = app.segmentedControls["overview.trendMode"]
        XCTAssertTrue(mode.exists)
        for _ in 0..<4 where mode.frame.minY < app.navigationBars.firstMatch.frame.maxY + 8 { scroll(app, up: false) }
        // Select through the real control. An argument-domain UserDefaults override would lock AppStorage in exp.
        mode.buttons["支出"].tap()
        let line = app.staticTexts["overview.trendLine"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        let height = chart.frame.height, bottom = line.frame.maxY - chart.frame.minY
        checkChartHue(app, chart: chart, theme: theme)
        capture(app, name: "\(theme)-\(appearance)-点选前")
        let before = line.label
        // Use an actual month's x position: an arbitrary percentage can land in the gap between categorical bars.
        let mark = chart.otherElements.matching(NSPredicate(format: "label ENDSWITH %@", "月 支出")).firstMatch
        XCTAssertTrue(mark.exists)
        XCTAssertGreaterThan(mark.frame.width, 0)
        chart.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: mark.frame.midX - chart.frame.minX, dy: chart.frame.height * 0.4)).tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in line.label != before }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, "Before: \(before); after: \(line.label); month: \(mark.label)")
        XCTAssertEqual(chart.frame.height, height, accuracy: 0.5)
        XCTAssertEqual(line.frame.maxY - chart.frame.minY, bottom, accuracy: 0.5)
        capture(app, name: "\(theme)-\(appearance)-\(large ? "最大字号" : "常用字号")-支出主题色")
        let flow = mode.buttons["收支"]
        XCTAssertTrue(flow.exists)
        flow.tap()
        let switched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            line.label.contains("收入") && line.label.contains("支出")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [switched], timeout: 5), .completed, line.label)
        XCTAssertEqual(chart.frame.height, height, accuracy: 0.5)
        XCTAssertEqual(line.frame.maxY - chart.frame.minY, bottom, accuracy: 0.5)
        capture(app, name: "\(theme)-\(appearance)-收支对比")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scroll(_ app: XCUIApplication, up: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.75 : 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.45 : 0.75))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func checkChartHue(_ app: XCUIApplication, chart: XCUIElement, theme: String) {
        let image = app.screenshot().image
        let screen = app.windows.firstMatch.frame
        let scale = CGFloat(image.cgImage!.width) / screen.width
        let rect = chart.frame.intersection(screen)
        guard let crop = image.cgImage?.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                                           width: rect.width * scale, height: rect.height * scale)) else {
            return XCTFail("The visible chart must be captured")
        }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                                    bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        var coloured = 0, matched = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            guard max(r, g, b) - min(r, g, b) > 40 else { continue }
            coloured += 1
            if theme == "blue" ? b > g && g > r : r > g && b > g {
                matched += 1
            }
        }
        XCTAssertGreaterThan(coloured, 100, "The chart must show actual bars")
        XCTAssertGreaterThan(Double(matched) / Double(max(1, coloured)), 0.95, "Single-series bars must follow \(theme)")
    }
}
