import XCTest
import AppIntents
@testable import Ledger

/// Shortcuts and Siri don't pass the app's lock screen: they need an unlocked phone, and with the app lock on the
/// spending and upcoming answers say to unlock the app instead of reading amounts out.
@MainActor
final class IntentLockTests: XCTestCase {
    private var was = false

    override func setUp() { was = UserDefaults.standard.bool(forKey: AppLock.enabledKey) }
    override func tearDown() { UserDefaults.standard.set(was, forKey: AppLock.enabledKey) }

    func testDataIntentsNeedAnUnlockedPhone() {
        for policy in [QuickRecordIntent.authenticationPolicy, MonthSpendIntent.authenticationPolicy, UpcomingIntent.authenticationPolicy] {
            XCTAssertEqual(policy, .requiresAuthentication)
        }
    }

    func testWithTheAppLockOnNothingIsReadOut() {
        UserDefaults.standard.set(true, forKey: AppLock.enabledKey)
        XCTAssertTrue(IntentLock.appLockOn)
        let reply = try? XCTUnwrap(IntentLock.readReply)
        XCTAssertNotNil(reply)
        XCTAssertFalse(reply?.contains("¥") ?? true)
        UserDefaults.standard.set(false, forKey: AppLock.enabledKey)
        XCTAssertNil(IntentLock.readReply)
    }
}
