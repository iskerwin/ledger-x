import XCTest
@testable import Ledger

/// Access tokens stay on this phone: in the keychain, or — when a sideloaded build's keychain refuses — in the
/// app's own protected file that backups leave out. Never in the settings (UserDefaults) in plain text.
final class KeychainTests: XCTestCase {
    private let account = "token.keychain-test"
    private var keychainAdd: ((CFDictionary) -> OSStatus)!
    private var writeFile: ((Data, URL) throws -> Void)!

    override func setUp() {
        keychainAdd = Keychain.add
        writeFile = Keychain.Fallback.writeFile
        Keychain.delete(account: account)
    }

    override func tearDown() {
        Keychain.add = keychainAdd
        Keychain.Fallback.writeFile = writeFile
        Keychain.delete(account: account)
    }

    private var inSettings: String? { UserDefaults.standard.string(forKey: "ledger.fallback." + account) }

    func testATokenTheKeychainRefusesIsNotWrittenToTheSettings() throws {
        Keychain.add = { _ in errSecMissingEntitlement }
        Keychain.save("secret-1", account: account)
        XCTAssertNil(inSettings)
        XCTAssertTrue(Keychain.inFallback(account: account))
        XCTAssertEqual(Keychain.load(account: account), "secret-1")
        let file = try XCTUnwrap(Keychain.Fallback.url(account))
        XCTAssertEqual(try file.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // removing the ledger removes the token
        Keychain.delete(account: account)
        XCTAssertNil(Keychain.load(account: account))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testATokenLeftInTheSettingsByAnEarlierVersionMovesOut() {
        Keychain.add = { _ in errSecMissingEntitlement }
        UserDefaults.standard.set("secret-2", forKey: "ledger.fallback." + account)
        XCTAssertEqual(Keychain.load(account: account), "secret-2")
        XCTAssertNil(inSettings, "moved out of the settings on first read")
        XCTAssertEqual(Keychain.load(account: account), "secret-2")
    }

    func testATokenNeitherPlaceTakesIsReportedAndTheOldOneStays() {
        Keychain.add = { _ in errSecMissingEntitlement }
        UserDefaults.standard.set("secret-3", forKey: "ledger.fallback." + account)
        Keychain.Fallback.writeFile = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertFalse(Keychain.save("secret-4", account: account))
        XCTAssertEqual(inSettings, "secret-3", "the earlier token is not thrown away")
        XCTAssertFalse(Keychain.inFallback(account: account))
    }
}
