import XCTest
import LocalAuthentication
@testable import Ledger

/// The lock turned on, then the passcode taken off the phone: the app stays locked and says how to get back in,
/// instead of letting anyone in.
@MainActor
final class AppLockTests: XCTestCase {
    private var was = false
    private var check: ((LAContext) -> Bool)!

    override func setUp() {
        was = UserDefaults.standard.bool(forKey: AppLock.enabledKey)
        check = AppLock.canAuthenticate
    }

    override func tearDown() {
        UserDefaults.standard.set(was, forKey: AppLock.enabledKey)
        AppLock.canAuthenticate = check
    }

    func testAPhoneWithoutAPasscodeStaysLocked() async {
        UserDefaults.standard.set(true, forKey: AppLock.enabledKey)
        let lock = AppLock()
        XCTAssertTrue(lock.locked)
        AppLock.canAuthenticate = { _ in false }
        await lock.unlock()
        XCTAssertTrue(lock.locked)
        XCTAssertNotNil(lock.lastError)
    }
}
