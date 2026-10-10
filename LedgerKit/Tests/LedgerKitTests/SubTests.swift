import XCTest
@testable import LedgerKit

/// subscription history, linked charges, detection and alerts
final class SubTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private let base = """
    option "operating_currency" "CNY"
    2023-01-01 open Assets:Bank:CMB CNY
    2023-01-01 open Liabilities:CreditCard:CMB CNY
    2023-01-01 open Expenses:Subscription CNY
    2023-01-01 open Expenses:Food CNY
    2023-01-01 open Equity:Opening CNY

    """

    private func charge(_ date: String, _ amount: String, payee: String = "Apple", link: String? = "sub-icloud", account: String = "Expenses:Subscription") -> String {
        "\(date) * \"\(payee)\" \"iCloud+\"\(link.map { " ^" + $0 } ?? "")\n  \(account)  \(amount) CNY\n  Liabilities:CreditCard:CMB\n"
    }

    func testLinkName() {
        XCTAssertEqual(subscriptionLink("iCloud+"), "sub-icloud")
        XCTAssertEqual(subscriptionLink("Apple Music"), "sub-apple-music")
        XCTAssertTrue(subscriptionLink("腾讯视频").hasPrefix("sub-"))
        XCTAssertEqual(subscriptionLink("腾讯视频"), subscriptionLink("腾讯视频"))
        XCTAssertNotEqual(subscriptionLink("腾讯视频"), subscriptionLink("爱奇艺"))
    }

    func testHistoryAndCharges() throws {
        var t = base + """
        2024-01-15 custom "subscription" "iCloud+" "monthly" 21.00 CNY
          account: "Expenses:Subscription"
          funding: "Liabilities:CreditCard:CMB"
          payee: "Apple"
          link: "sub-icloud"
        2025-03-01 custom "subscription" "iCloud+" "paused"
        2025-06-10 custom "subscription" "iCloud+" "monthly" 25.00 CNY

        """
        t += charge("2024-01-15", "1.00")                       // intro price
        for m in 2...12 { t += charge(String(format: "2024-%02d-15", m), "21.00") }
        for m in 1...2 { t += charge(String(format: "2025-%02d-15", m), "21.00") }
        for m in 6...9 { t += charge(String(format: "2025-%02d-10", m), "25.00") }
        t += charge("2025-07-20", "8.00", payee: "Other", link: nil)  // not linked
        let L = ledger(t)
        XCTAssertTrue(L.errors.isEmpty, L.errors.map { $0.msg }.joined(separator: "; "))
        let s = try XCTUnwrap(subscriptions(L).first)
        XCTAssertEqual(s.status, .active)
        XCTAssertEqual(s.amount, 25)
        XCTAssertEqual(s.start, "2024-01-15")
        XCTAssertEqual(s.since, "2025-06-10")
        XCTAssertEqual(s.account, "Expenses:Subscription")         // carried over from the first line
        XCTAssertEqual(s.events.map { $0.kind }, [.start, .pause, .resume])
        XCTAssertEqual(s.charges.count, 18)
        XCTAssertEqual(s.totalPaid, 1 + 21 * 13 + 25 * 4, accuracy: 0.001)
        XCTAssertEqual(s.paid(in: "2025"), 21 * 2 + 25 * 4, accuracy: 0.001)
        // the cycle follows the latest charge
        XCTAssertEqual(s.anchor, "2025-09-10")
        XCTAssertEqual(s.due(onOrAfter: "2025-09-20"), "2025-10-10")

        let tl = subscriptionTimeline(s)
        let runs = tl.filter { $0.kind == .run }
        XCTAssertEqual(runs.count, 3)
        XCTAssertTrue(runs.contains { $0.from == "2024-01-15" && $0.to == nil && $0.title.contains("1.00") })     // first charge
        XCTAssertTrue(runs.contains { $0.from == "2024-02-15" && $0.to == "2025-02-15" })
        XCTAssertTrue(runs.contains { $0.from == "2025-06-10" && $0.to == "2025-09-10" })
        XCTAssertEqual(tl.filter { $0.kind == .gap }.count, 1)
        XCTAssertEqual(tl.first?.from, "2025-06-10")            // newest first: the latest run, then the resume
        XCTAssertEqual(tl.first?.kind, .run)
    }

    func testStateLinesAndAlerts() throws {
        var t = base + """
        2026-01-05 custom "subscription" "Video" "monthly" 30.00 CNY
          account: "Expenses:Subscription"
          funding: "Assets:Bank:CMB"
          payee: "Video"
        2026-05-01 custom "subscription" "Video" "cancelled"

        """
        for m in 1...4 { t += "2026-0\(m)-05 * \"Video\" \"\" ^sub-video\n  Expenses:Subscription  30.00 CNY\n  Liabilities:CreditCard:CMB\n" }
        t += "2026-05-05 * \"Video\" \"\" ^sub-video\n  Expenses:Subscription  30.00 CNY\n  Liabilities:CreditCard:CMB\n"
        let L = ledger(t)
        let s = try XCTUnwrap(subscriptions(L).first)
        XCTAssertEqual(s.link, "sub-video")
        XCTAssertEqual(s.status, .cancelled)
        XCTAssertEqual(s.statusDate, "2026-05-01")
        let kinds = subscriptionAlerts(s, today: "2026-05-10").map { $0.kind }
        XCTAssertTrue(kinds.contains(.chargedWhileInactive))
        XCTAssertTrue(subscriptionsDue(L, today: "2026-06-10").isEmpty)    // cancelled: never due

        // a price change and a different card show up on an active plan
        var u = base + "2026-01-05 custom \"subscription\" \"Video\" \"monthly\" 30.00 CNY\n  account: \"Expenses:Subscription\"\n  funding: \"Assets:Bank:CMB\"\n\n"
        u += "2026-02-05 * \"Video\" \"\" ^sub-video\n  Expenses:Subscription  35.00 CNY\n  Liabilities:CreditCard:CMB\n"
        let a = subscriptionAlerts(try XCTUnwrap(subscriptions(ledger(u)).first), today: "2026-02-10")
        XCTAssertEqual(a.first { $0.kind == .priceChanged }?.amount, 35)
        XCTAssertEqual(a.first { $0.kind == .fundingChanged }?.account, "Liabilities:CreditCard:CMB")
        // nothing for months
        let quiet = subscriptionAlerts(try XCTUnwrap(subscriptions(ledger(u)).first), today: "2026-06-10")
        XCTAssertTrue(quiet.contains { $0.kind == .silent })
    }

    func testCandidatesWithIntroAndPause() throws {
        var t = base
        t += charge("2025-11-03", "1.00", payee: "Spotify", link: nil)
        for d in ["2025-12-03", "2026-01-03", "2026-02-03", "2026-06-03", "2026-07-03", "2026-08-03", "2026-09-03"] {
            t += charge(d, "15.00", payee: "Spotify", link: nil)
        }
        // a yearly one, twice
        t += charge("2024-10-01", "98.00", payee: "Keep", link: nil)
        t += charge("2025-10-01", "98.00", payee: "Keep", link: nil)
        // not regular
        t += charge("2026-08-01", "15.00", payee: "Cafe", link: nil, account: "Expenses:Food")
        t += charge("2026-08-04", "22.00", payee: "Cafe", link: nil, account: "Expenses:Food")
        t += charge("2026-09-20", "15.00", payee: "Cafe", link: nil, account: "Expenses:Food")
        let L = ledger(t)
        let c = subscriptionCandidates(L, today: "2026-09-20")
        let spotify = try XCTUnwrap(c.first { $0.payee == "Spotify" })
        XCTAssertEqual(spotify.period, .monthly)
        XCTAssertEqual(spotify.amount, 15)
        XCTAssertEqual(spotify.first, "2025-11-03")
        XCTAssertEqual(spotify.txns.count, 8)
        let keep = try XCTUnwrap(c.first { $0.payee == "Keep" })
        XCTAssertEqual(keep.period, .yearly)
        XCTAssertFalse(c.contains { $0.payee == "Cafe" })
    }

    func testMatchingNewCharges() throws {
        let t = base + "2026-01-05 custom \"subscription\" \"iCloud+\" \"monthly\" 21.00 CNY\n  account: \"Expenses:Subscription\"\n  payee: \"Apple\"\n"
        let subs = subscriptions(ledger(t))
        XCTAssertEqual(matchSubscription(payee: "Apple", account: "Expenses:Subscription", amount: 21, currency: "CNY", subs)?.name, "iCloud+")
        XCTAssertEqual(matchSubscription(payee: "Apple", account: "Expenses:Subscription", amount: 25, currency: "CNY", subs)?.name, "iCloud+")
        XCTAssertNil(matchSubscription(payee: "Apple", account: "Expenses:Food", amount: 21, currency: "CNY", subs))
        XCTAssertNil(matchSubscription(payee: "Apple", account: "Expenses:Subscription", amount: 300, currency: "CNY", subs))
        // the state line text parses back
        let paused = ledger(t + "\n" + subscriptionStateText("iCloud+", .paused, date: "2026-03-01") + "\n")
        XCTAssertEqual(subscriptions(paused).first?.status, .paused)
    }
}
