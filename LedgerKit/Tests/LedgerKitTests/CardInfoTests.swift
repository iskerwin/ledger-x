import XCTest
@testable import LedgerKit

final class CardInfoTests: XCTestCase {
    func testTheNumberIsKeptAsDigitsAndShownInGroups() {
        XCTAssertEqual(cardDigits("4111 1111-1111 1111"), "4111111111111111")
        XCTAssertEqual(cardDigits("１２３4"), "4", "full-width digits are not card digits")
        XCTAssertEqual(cardDigits(String(repeating: "1", count: 25)).count, 19)
        XCTAssertEqual(groupedCardNumber("4111111111111111"), "4111 1111 1111 1111")
        XCTAssertEqual(groupedCardNumber("378282246310005"), "3782 822463 10005")
        XCTAssertEqual(groupedCardNumber("6212345678901234567"), "6212 3456 7890 1234 567")
        XCTAssertEqual(groupedCardNumber("41111"), "4111 1")
    }

    func testTheCheckDigitCatchesATypo() {
        XCTAssertTrue(cardNumberValid("4111111111111111"))
        XCTAssertTrue(cardNumberValid("378282246310005"))
        XCTAssertTrue(cardNumberValid("5555555555554444"))
        XCTAssertFalse(cardNumberValid("4111111111111112"), "one digit wrong")
        XCTAssertFalse(cardNumberValid("41111111111"), "too short")
        XCTAssertFalse(cardNumberValid(""))
    }

    func testTheExpiryIsReadAsAMonthOfAYear() {
        XCTAssertEqual(normalizedExpiry("0628"), "06/28")
        XCTAssertEqual(normalizedExpiry("06/28"), "06/28")
        XCTAssertEqual(normalizedExpiry("6/28"), "06/28")
        XCTAssertEqual(normalizedExpiry("06/2028"), "06/28")
        XCTAssertEqual(normalizedExpiry("062028"), "06/28")
        XCTAssertNil(normalizedExpiry("13/28"))
        XCTAssertNil(normalizedExpiry("00/28"))
        XCTAssertNil(normalizedExpiry("06/2"))
        XCTAssertNil(normalizedExpiry("628"))
        XCTAssertNil(normalizedExpiry("ab/cd"))
        XCTAssertNil(normalizedExpiry(""))
    }

    func testTheSecurityCodeIsThreeOrFourDigits() {
        XCTAssertTrue(cvvValid("123"))
        XCTAssertTrue(cvvValid("1234"))
        XCTAssertFalse(cvvValid("12"))
        XCTAssertFalse(cvvValid("12345"))
        XCTAssertFalse(cvvValid("12a"))
    }

    func testTheLastFourAreOnlyTakenFromAWholeNumber() {
        XCTAssertEqual(CardInfo(number: "4111111111111111").last4, "1111")
        XCTAssertNil(CardInfo(number: "4111").last4)
        XCTAssertTrue(CardInfo().isEmpty)
        XCTAssertFalse(CardInfo(holder: "Example").isEmpty)
    }

    func testARenamedAccountKeepsItsCard() {
        let a = CardInfo(number: "4111111111111111"), b = CardInfo(number: "5555555555554444")
        let moved = renamedCardInfos(["Assets:Bank:Old": a, "Assets:Bank:Old:Sub": b, "Assets:Cash": CardInfo()], from: "Assets:Bank:Old", to: "Assets:Bank:New")
        XCTAssertEqual(moved["Assets:Bank:New"], a)
        XCTAssertEqual(moved["Assets:Bank:New:Sub"], b)
        XCTAssertNil(moved["Assets:Bank:Old"])
        XCTAssertEqual(moved.count, 3)
        // merged into one that has its own: that one stays
        let merged = renamedCardInfos(["Assets:Bank:Old": a, "Assets:Bank:New": b], from: "Assets:Bank:Old", to: "Assets:Bank:New")
        XCTAssertEqual(merged, ["Assets:Bank:New": b])
    }
}
