import XCTest
@testable import Ledger

/// The app lock covers the app's screens, not a ledger kept on this phone, which the Files app opens directly:
/// with the lock on, Settings says so when there is such a ledger.
@MainActor
final class FilesExposureTests: XCTestCase {
    func testOnlyALedgerOnThisPhoneIsInTheFilesApp() {
        var git = RepoConfig()
        git.kind = .github
        var local = RepoConfig()
        local.kind = .local
        XCTAssertFalse(Store.hasLedgerInFiles([git]))
        XCTAssertTrue(Store.hasLedgerInFiles([git, local]))
    }
}
