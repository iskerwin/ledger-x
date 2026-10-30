import XCTest
import SwiftUI
@testable import Ledger

/// A failure leads with a warning mark and a done thing with a check (most used to be plain); a long message is
/// shown whole (it was cut after two lines).
@MainActor
final class ToastKindTests: XCTestCase {
    private func shown(_ store: Store) async -> Toast? {
        for _ in 0..<40 where store.toast == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        return store.toast
    }

    func testFailureAndSuccessNoticesLookTheirKind() async {
        let failing = Store()
        failing.showFailure("fictional failure")
        let failure = await shown(failing)
        XCTAssertEqual(failure?.failure, true)
        XCTAssertEqual(failure?.success, false)

        let done = Store()
        done.showSuccess("fictional copy")
        let success = await shown(done)
        XCTAssertEqual(success?.success, true)
        XCTAssertEqual(success?.failure, false)
    }

    func testALongMessageIsShownWhole() throws {
        let store = Store()
        let text = String(repeating: "附件没有上传完成，恢复副本已保留在本机，可以稍后重试。", count: 3)
        store.toast = Toast(text: text, failure: true)
        let short = Store()
        short.toast = Toast(text: "已复制", success: true)
        func height(_ s: Store) throws -> Int {
            let renderer = ImageRenderer(content: ToastView(top: true).environment(s).frame(width: 330))
            renderer.scale = 1
            return try XCTUnwrap(renderer.cgImage).height
        }
        // well over two lines of subheadline (about 20 pt each) above the one-line notice
        XCTAssertGreaterThan(try height(store), try height(short) + 50)
    }
}
