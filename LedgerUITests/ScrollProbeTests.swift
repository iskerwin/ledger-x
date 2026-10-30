import XCTest

/// Probe: how much the overview hitches when scrolled back up, with and without 值得留意 on it.
/// The extra entries are written relative to today, so the alerts (which look at the last month) show up.
final class ScrollProbeTests: XCTestCase {
    func testScrollBackUpWithAlerts() { measureScrollBack(alerts: true) }

    func testScrollBackUpWithoutAlerts() { measureScrollBack(alerts: false) }

    private func extra(alerts: Bool) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let day = { (back: Int) in f.string(from: Calendar.current.date(byAdding: .day, value: -back, to: Date())!) }
        let cats = ["Dining", "Grocery", "Transport", "Coffee", "Books", "Phone", "Rent", "Gym", "Movies", "Gifts", "Pets", "Travel"]
        var s = cats.map { "2026-01-01 open Expenses:\($0) CNY\n" }.joined()
        for back in 1...50 {
            for (i, c) in cats.enumerated() where (back + i) % 3 == 0 {
                s += "\n\(day(back)) * \"Shop \(c)\" \"\(c) \(back)\"\n  Expenses:\(c)  \(10 + (back * 7 + i * 13) % 90).00 CNY\n  Assets:Cash\n"
            }
        }
        if alerts {
            for _ in 0..<2 { s += "\n\(day(3)) * \"Twice shop\" \"Charged twice\"\n  Expenses:Dining  42.00 CNY\n  Assets:Cash\n" }
            for _ in 0..<2 { s += "\n\(day(5)) * \"Again shop\" \"Charged twice\"\n  Expenses:Coffee  31.00 CNY\n  Assets:Cash\n" }
            s += "\n\(day(2)) * \"Big trip\" \"Flights\"\n  Expenses:Travel  6800.00 CNY\n  Assets:Cash\n"
            s += "\n\(day(4)) * \"Big shop\" \"Laptop\"\n  Expenses:Gifts  5200.00 CNY\n  Assets:Cash\n"
        }
        return s
    }

    private func measureScrollBack(alerts: Bool) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(alerts).bean")
        XCTAssertNoThrow(try extra(alerts: alerts).write(to: url, atomically: true, encoding: .utf8))
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_EXTRA": url.path, "LEDGER_TAB": "overview", "LEDGER_LANG": "zh"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.otherElements["overview.hero"].waitForExistence(timeout: 20))
        let header = app.staticTexts["值得留意"].firstMatch
        _ = header.waitForExistence(timeout: 3)
        print("PROBE alerts=\(alerts) section=\(header.exists)")
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app)], options: options) {
            for _ in 0..<6 { app.swipeUp(velocity: .fast) }
            startMeasuring()
            for _ in 0..<6 { app.swipeDown(velocity: .slow) }
            stopMeasuring()
        }
    }
}
