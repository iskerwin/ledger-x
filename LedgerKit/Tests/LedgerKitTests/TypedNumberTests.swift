import XCTest
@testable import LedgerKit

/// numbers typed with a Chinese or Japanese input method on: 。 for the point, full-width digits and signs
final class TypedNumberTests: XCTestCase {
    func testTheIdeographicFullStopIsTheDecimalPoint() {
        XCTAssertEqual(evalAmount("12。5"), 12.5)
        XCTAssertEqual(typedNumber("7。12"), 7.12)
    }

    func testFullWidthDigitsAndSignsAreRead() {
        XCTAssertEqual(evalAmount("１２．５＋３"), 15.5)
        XCTAssertEqual(evalExpr("１０＊２"), 20)
        XCTAssertEqual(evalExpr("ー5"), -5)
    }

    func testPlainTypingIsUnchanged() {
        XCTAssertEqual(asciiTyped("12.5+3"), "12.5+3")
        XCTAssertEqual(asciiTyped("午饭"), "午饭")
        XCTAssertNil(typedNumber("abc"))
    }

    func testACreditLimitTypedFullWidthIsAccepted() {
        XCTAssertEqual(typedNumber("５００００"), 50000)
    }
}
