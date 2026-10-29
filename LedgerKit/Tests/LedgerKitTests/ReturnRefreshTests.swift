import XCTest
@testable import LedgerKit

final class ReturnRefreshTests: XCTestCase {
    func testAQuickReturnDoesNotFetchAgain() {
        let last = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(ReturnRefresh.due(lastSync: last, now: last.addingTimeInterval(20), waiting: false))
        XCTAssertTrue(ReturnRefresh.due(lastSync: last, now: last.addingTimeInterval(60), waiting: false))
        XCTAssertTrue(ReturnRefresh.due(lastSync: nil, now: last, waiting: false), "never fetched")
        XCTAssertTrue(ReturnRefresh.due(lastSync: last, now: last.addingTimeInterval(5), waiting: true), "something to send")
        XCTAssertTrue(ReturnRefresh.due(lastSync: last, now: last.addingTimeInterval(-5), waiting: false), "clock set back")
    }
}
