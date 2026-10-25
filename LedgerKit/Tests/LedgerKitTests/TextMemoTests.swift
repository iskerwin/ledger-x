import XCTest
@testable import LedgerKit

/// The in-memory half of the blob cache: a sha's text is kept, and "is it here" does not copy it out.
final class TextMemoTests: XCTestCase {
    func testGetSetContainsAndPrune() {
        let memo = TextMemo()
        XCTAssertFalse(memo.contains("abc"))
        XCTAssertNil(memo.get("abc"))
        memo.set("abc", "hello")
        memo.set("def", "world")
        XCTAssertTrue(memo.contains("abc"))
        XCTAssertEqual(memo.get("abc"), "hello")
        // a second write replaces the text; the key is still just present
        memo.set("abc", "hello again")
        XCTAssertEqual(memo.get("abc"), "hello again")
        memo.prune { $0 == "abc" }
        XCTAssertTrue(memo.contains("abc"))
        XCTAssertFalse(memo.contains("def"))
        XCTAssertNil(memo.get("def"))
        memo.clear()
        XCTAssertFalse(memo.contains("abc"))
        XCTAssertNil(memo.get("abc"))
    }
}
