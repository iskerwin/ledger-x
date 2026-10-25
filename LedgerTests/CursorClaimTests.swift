import XCTest
import UIKit
@testable import Ledger

@MainActor
final class CursorClaimTests: XCTestCase {
    private func host() -> (UIWindow, UITextField, ClaimFocusView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        let row = UIView(frame: CGRect(x: 20, y: 100, width: 320, height: 50))
        let field = UITextField(frame: row.bounds)
        let claim = ClaimFocusView(frame: row.bounds)
        claim.isUserInteractionEnabled = false
        row.addSubview(field)
        row.addSubview(claim)
        controller.view.addSubview(row)
        window.makeKeyAndVisible()
        return (window, field, claim)
    }

    func testSuccessfulClaimDoesNotTakeFocusBackAfterKeyboardDismissal() async {
        let (window, field, claim) = host()
        defer { window.isHidden = true }
        let placed = expectation(description: "cursor placed")
        claim.onClaimed = { placed.fulfill() }
        claim.request = UUID()
        await fulfillment(of: [placed], timeout: 3)
        XCTAssertTrue(field.isFirstResponder)
        field.resignFirstResponder()
        // Further layouts used to leave a live timer able to take focus back for six seconds.
        let reclaimed = expectation(forNotification: UITextField.textDidBeginEditingNotification, object: field)
        reclaimed.isInverted = true
        claim.setNeedsLayout()
        claim.layoutIfNeeded()
        await fulfillment(of: [reclaimed], timeout: 0.5)
        XCTAssertFalse(field.isFirstResponder)
    }

    func testCancelledClaimCannotRunWhenTheFieldArrives() async {
        let (window, field, claim) = host()
        defer { window.isHidden = true }
        let placed = expectation(description: "cancelled request must not complete")
        placed.isInverted = true
        claim.onClaimed = { placed.fulfill() }
        claim.request = UUID()
        claim.request = nil
        claim.layoutIfNeeded()
        await fulfillment(of: [placed], timeout: 0.5)
        XCTAssertFalse(field.isFirstResponder)
    }

    func testNewRequestCanFocusTheSameFieldAgainAfterDismissal() async {
        let (window, field, claim) = host()
        defer { window.isHidden = true }
        let first = expectation(description: "first validation")
        claim.onClaimed = { first.fulfill() }
        claim.request = UUID()
        await fulfillment(of: [first], timeout: 3)
        field.resignFirstResponder()
        let second = expectation(description: "next validation")
        claim.onClaimed = { second.fulfill() }
        claim.request = UUID()
        await fulfillment(of: [second], timeout: 3)
        XCTAssertTrue(field.isFirstResponder)
    }
}
