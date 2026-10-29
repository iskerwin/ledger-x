import XCTest
@testable import LedgerKit

final class LastResultTests: XCTestCase {
    func testTheSameKeyIsNotWorkedOutAgain() {
        let kept = LastResult<String, Int>()
        var made = 0
        XCTAssertEqual(kept.value(for: "a") { made += 1; return 1 }, 1)
        XCTAssertEqual(kept.value(for: "a") { made += 1; return 2 }, 1)
        XCTAssertEqual(made, 1)
        XCTAssertEqual(kept.value(for: "b") { made += 1; return 3 }, 3)
        XCTAssertEqual(kept.value(for: "a") { made += 1; return 4 }, 4, "only the last one is kept")
        XCTAssertEqual(made, 3)
    }
}
