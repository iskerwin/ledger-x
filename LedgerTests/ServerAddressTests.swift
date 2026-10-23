import XCTest
@testable import Ledger

/// A self-hosted server may be reached over http (one on the home network): allowed, but the connection form warns
/// that the token and the ledger then travel unencrypted.
final class ServerAddressTests: XCTestCase {
    private func config(_ kind: SourceKind, _ server: String) -> RepoConfig {
        var c = RepoConfig()
        c.kind = kind
        c.server = server
        return c
    }

    func testOnlyAPlainHttpServerIsFlagged() {
        XCTAssertTrue(config(.gitea, "http://192.168.1.20:3000").sendsInPlainText)
        XCTAssertTrue(config(.webdav, " HTTP://nas.local/dav/ledger/").sendsInPlainText)
        XCTAssertTrue(config(.gitlab, "http://gitlab.home").sendsInPlainText)
        XCTAssertFalse(config(.webdav, "https://dav.jianguoyun.com/dav/ledger/").sendsInPlainText)
        XCTAssertFalse(config(.gitlab, "").sendsInPlainText, "empty: gitlab.com over https")
        XCTAssertFalse(config(.github, "http://example.com").sendsInPlainText, "GitHub has no server field")
    }
}
