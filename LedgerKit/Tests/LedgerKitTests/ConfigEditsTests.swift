import XCTest
@testable import LedgerKit

/// ledger-x.json changes said as what changes: two in a row both stay, whatever order they land in.
final class ConfigEditsTests: XCTestCase {
    func testTwoQuickChangesBothStay() {
        // each change is applied to the file as the one before it left it (Store.updateConfig runs them in turn)
        var c = LedgerXConfig()
        c.pinTemplate("a")
        c.pinTemplate("b")
        XCTAssertEqual(c.templatesPinned, ["a", "b"])
        // hiding one: two changes (hidden, and no longer pinned) in one, so neither can undo the other
        c.hideTemplate("a")
        XCTAssertEqual(c.templatesPinned, ["b"])
        XCTAssertEqual(c.templatesHidden, ["a"])
    }

    func testTemplates() {
        var c = LedgerXConfig()
        c.pinTemplate("a"); c.pinTemplate("a")
        XCTAssertEqual(c.templatesPinned, ["a"], "pinning twice pins once")
        c.hideTemplate("a")
        XCTAssertEqual(c.templatesHidden, ["a"])
        XCTAssertEqual(c.templatesPinned, [], "a hidden template isn't pinned")
        c.unpinTemplate("zz")
        c.unhideAllTemplates()
        XCTAssertEqual(c.templatesHidden, [])
    }

    func testAlertsLinksSubs() {
        var c = LedgerXConfig()
        c.confirmAlert("x"); c.confirmAlert("y"); c.confirmAlert("x")
        XCTAssertEqual(c.alertsConfirmed, ["x", "y"])
        c.unconfirmAlert("x")
        XCTAssertEqual(c.alertsConfirmed, ["y"])
        c.alertsConfirmed = (0..<500).map { "old\($0)" }
        c.confirmAlert("new", live: ["new", "old3"])
        XCTAssertEqual(Set(c.alertsConfirmed ?? []), ["new", "old3"], "over 500: only those that can still come up")
        c.ignoreLink("k1"); c.ignoreLink("k1"); c.ignoreLink("k2")
        XCTAssertEqual(c.linksIgnored, ["k1", "k2"])
        c.clearIgnoredLinks()
        XCTAssertEqual(c.linksIgnored, [])
        c.ignoreSubSuggestion("s"); c.ignoreSubSuggestion("s")
        XCTAssertEqual(c.subsIgnored, ["s"])
    }

    func testSearchesFoundByWhatTheyAre() {
        let a = QuickSearch(name: "旅行", query: "#trip"), b = QuickSearch(name: "本月", query: "本月"), b2 = QuickSearch(name: "这个月", query: "本月")
        var c = LedgerXConfig()
        c.saveSearch(a); c.saveSearch(b); c.saveSearch(a)
        XCTAssertEqual(c.searches, [a, b])
        c.saveSearch(b2, replacing: b)
        XCTAssertEqual(c.searches, [a, b2], "changed where it is")
        c.moveSearch(b2, by: -1)
        XCTAssertEqual(c.searches, [b2, a])
        c.moveSearch(b2, by: -1)
        XCTAssertEqual(c.searches, [b2, a], "nowhere to go")
        // removed on another device meanwhile: a change to it becomes a new one, a removal does nothing
        c.removeSearch(a)
        c.saveSearch(QuickSearch(name: "旅行 2", query: "#trip"), replacing: a)
        XCTAssertEqual(c.searches?.map { $0.name }, ["这个月", "旅行 2"])
        c.removeSearch(a)
        XCTAssertEqual(c.searches?.count, 2)
    }
}
