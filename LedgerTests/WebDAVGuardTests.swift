import XCTest
@testable import Ledger

/// A WebDAV server guards a write only with a strong ETag (If-Match). With weak or no ETags on the ledger files the
/// sync page says two devices saving at once can overwrite each other.
final class WebDAVGuardTests: XCTestCase {
    private func items(_ etag: String) -> [(path: String, item: WebDAV.Item)] {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/dav/ledger/main.bean</d:href><d:propstat><d:prop>
            <d:resourcetype/>\(etag)<d:getlastmodified>Fri, 24 Oct 2026 08:00:00 GMT</d:getlastmodified><d:getcontentlength>120</d:getcontentlength>
          </d:prop></d:propstat></d:response>
        </d:multistatus>
        """
        return DAVParser.parse(Data(xml.utf8)).map { ("main.bean", $0) }
    }

    func testOnlyStrongETagsGuardTheLedgerFiles() {
        XCTAssertFalse(WebDAV.unguarded(items("<d:getetag>\"abc123\"</d:getetag>")))
        XCTAssertTrue(WebDAV.unguarded(items("<d:getetag>W/\"abc123\"</d:getetag>")))
        XCTAssertTrue(WebDAV.unguarded(items("")))
        // an attachment without an ETag doesn't matter: only ledger text is merged and overwritten
        let photo = items("").map { (path: "documents/receipt.jpg", item: $0.item) }
        XCTAssertFalse(WebDAV.unguarded(photo))
    }
}
