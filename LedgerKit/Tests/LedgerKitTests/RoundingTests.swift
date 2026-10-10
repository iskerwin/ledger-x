import XCTest
@testable import LedgerKit

/// Pin down the money-rounding semantics so a "harmless" refactor can't
/// silently move a cent: ties go toward +∞ (JS `Math.round`), and the known
/// divergences from real JS are asserted as-is, not as bugs to trip over.
final class RoundingTests: XCTestCase {
    func testJsRoundTiesTowardPositiveInfinity() {
        XCTAssertEqual(jsRound(2.5), 3)
        XCTAssertEqual(jsRound(-2.5), -2)   // NOT away-from-zero (-3)
        XCTAssertEqual(jsRound(2.4), 2)
        XCTAssertEqual(jsRound(-2.4), -2)
        XCTAssertEqual(jsRound(2.6), 3)
        XCTAssertEqual(jsRound(-2.6), -3)
        XCTAssertEqual(jsRound(0.5), 1)
        XCTAssertEqual(jsRound(-0.5), 0)
    }

    func testRoundTo() {
        // 2.675 is really 2.6749999999999998 in binary: no exact tie, rounds down.
        XCTAssertEqual(roundTo(2.675, 2), 2.67)
        XCTAssertEqual(roundTo(-2.675, 2), -2.67)
        XCTAssertEqual(roundTo(2.5, 0), 3)
        XCTAssertEqual(roundTo(-2.5, 0), -2)
        XCTAssertEqual(roundTo(123.456, 2), 123.46, accuracy: 1e-9)
        XCTAssertEqual(roundTo(1.005, 2), 1.0, accuracy: 1e-9) // binary 1.0049999…
    }

    func testToFixed() {
        XCTAssertEqual(toFixed(0.5, 0), "1")
        XCTAssertEqual(toFixed(1.5, 0), "2")
        XCTAssertEqual(toFixed(2.5, 0), "3")
        XCTAssertEqual(toFixed(-1.5, 0), "-2") // exact ties away from zero…
        XCTAssertEqual(toFixed(-2.5, 0), "-3")
        XCTAssertEqual(toFixed(2.675, 2), "2.67") // …but binary 2.6749999… isn't one
        XCTAssertEqual(toFixed(123.456, 2), "123.46")
        XCTAssertEqual(toFixed(0, 2), "0.00")
        // negative zero is stripped; real JS keeps "-0.00" — locked in deliberately
        XCTAssertEqual(toFixed(-0.001, 2), "0.00")
    }

    func testJsNumberString() {
        XCTAssertEqual(jsNumberString(123), "123")
        XCTAssertEqual(jsNumberString(-45), "-45")
        XCTAssertEqual(jsNumberString(0.30000000000000004), "0.30000000000000004")
        XCTAssertEqual(jsNumberString(Double.nan), "NaN")
        // known divergences from real JS, locked in deliberately:
        XCTAssertEqual(jsNumberString(1e15), "1000000000000000.0") // JS: "1000000000000000"
        XCTAssertEqual(jsNumberString(1e-7), "0.0000001")          // JS: "1e-7"
        XCTAssertEqual(jsNumberString(Double.infinity), "inf")    // JS: "Infinity"
    }
}
