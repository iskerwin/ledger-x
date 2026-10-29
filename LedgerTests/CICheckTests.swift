import XCTest
@testable import Ledger

/// The bean-check run is asked for after a sync only when there is something new to know; it used to be asked
/// after every sync, even when nothing had changed.
@MainActor
final class CICheckTests: XCTestCase {
    func testTheRunIsAskedForOnlyWhenThereIsSomethingNew() {
        let head = "c2"
        XCTAssertTrue(Store.ciDue(nil, askedAt: nil, head: head), "never asked")
        XCTAssertFalse(Store.ciDue(.init(state: .ok, sha: head), askedAt: head, head: head), "the latest commit passed")
        XCTAssertFalse(Store.ciDue(.init(state: .fail, sha: head), askedAt: head, head: head))
        XCTAssertTrue(Store.ciDue(.init(state: .ok, sha: "c1"), askedAt: "c1", head: head), "a new commit")
        XCTAssertTrue(Store.ciDue(.init(state: .ok, sha: "c1"), askedAt: head, head: head), "the new commit's run not started yet")
        XCTAssertTrue(Store.ciDue(.init(state: .running, sha: head), askedAt: head, head: head))
        XCTAssertTrue(Store.ciDue(.init(state: .error), askedAt: head, head: head))
        XCTAssertFalse(Store.ciDue(.init(state: .empty), askedAt: head, head: head), "no workflow: once per commit")
        XCTAssertFalse(Store.ciDue(.init(state: .noperm), askedAt: head, head: head))
        XCTAssertTrue(Store.ciDue(.init(state: .empty), askedAt: "c1", head: head))
    }
}
