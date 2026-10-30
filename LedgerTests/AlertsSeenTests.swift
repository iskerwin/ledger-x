import XCTest
@testable import Ledger
import LedgerKit

/// 值得留意 on the overview remembers which alerts were seen as each row scrolls into view. Scrolling them back
/// into view wrote the same list again every time, and the overview hitched at the section's edge. Fictional data only.
@MainActor
final class AlertsSeenTests: XCTestCase {
    private final class Count { var n = 0 }

    private func fixture(_ text: String) async throws -> Store {
        let store = Store()
        var config = RepoConfig()
        config.id = "alerts-seen-test-" + UUID().uuidString
        config.kind = .local
        config.folderName = config.id
        let root = FolderBackend.localRoot(config.folderName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: root.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
        store.cfg = config
        store.pending = []
        store.mainFile = "main.bean"
        await store.refresh()
        addTeardownBlock { @MainActor in
            UserDefaults.standard.removeObject(forKey: "ledger." + store.pk("alerts.seen"))
            try? FileManager.default.removeItem(at: root)
        }
        return store
    }

    func testAlertsScrolledBackIntoViewAreNotWrittenAgain() async throws {
        let day = Day.shift(Day.today(), -2)
        let store = try await fixture("""
        2026-01-01 open Assets:Cash CNY
        2026-01-01 open Expenses:Food CNY

        \(day) * "Example cafe" "Charged twice"
          Expenses:Food                                        42.00 CNY
          Assets:Cash

        \(day) * "Example cafe" "Charged twice"
          Expenses:Food                                        42.00 CNY
          Assets:Cash
        """)
        XCTAssertFalse(store.anomalyList.isEmpty)
        // the first time in view: remembered, so no notification is sent for it
        store.markAlertsSeen()
        XCTAssertTrue(store.unseenAlerts.isEmpty)
        let writes = Count()
        let token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in writes.n += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        // each row scrolling back into view: nothing new, nothing written
        for _ in 0..<3 { store.markAlertsSeen() }
        XCTAssertEqual(writes.n, 0)
        XCTAssertTrue(store.unseenAlerts.isEmpty)
    }
}
