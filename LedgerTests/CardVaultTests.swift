import XCTest
@testable import Ledger
import LedgerKit

/// 卡片信息 stays on this phone per ledger: in the keychain (never the settings), gone with the ledger, moved with a
/// renamed account, and its last four digits stand in for a 尾号 the ledger does not give.
@MainActor
final class CardVaultTests: XCTestCase {
    private let card = CardInfo(number: "4111111111111111", expiry: "06/28", cvv: "123", holder: "Example Holder")

    func testACardIsKeptPerLedgerAndGoesWithIt() {
        let store = Store()
        var current = RepoConfig(); current.id = "cards-current-" + UUID().uuidString; current.kind = .local
        let other = "cards-other-" + UUID().uuidString
        store.cfg = current
        defer { CardVault.delete(ledger: current.id); CardVault.delete(ledger: other) }
        XCTAssertTrue(store.setCardInfo(card, for: "Assets:Bank:Example"))
        XCTAssertEqual(store.cardInfo("Assets:Bank:Example"), card)
        XCTAssertEqual(store.cardHints["Assets:Bank:Example"], CardHint(last4: "1111", expiry: "06/28"))
        XCTAssertEqual(store.cardTail("Assets:Bank:Example"), "1111", "no 尾号 in the ledger: the number's last four")
        // nothing of it in the settings
        let settings = UserDefaults.standard.dictionaryRepresentation().values.compactMap { $0 as? String }
        XCTAssertFalse(settings.contains { $0.contains("4111111111111111") })
        // another ledger has its own
        XCTAssertTrue(CardVault.load(ledger: other).isEmpty)
        XCTAssertTrue(CardVault.save(["Assets:Bank:Example": card], ledger: other))
        store.removeLedger(other)
        XCTAssertTrue(CardVault.load(ledger: other).isEmpty, "removing a ledger removes its cards")
        XCTAssertEqual(store.cardInfo("Assets:Bank:Example"), card, "the open ledger keeps its own")
        // an empty card is removed
        XCTAssertTrue(store.setCardInfo(CardInfo(), for: "Assets:Bank:Example"))
        XCTAssertNil(store.cardInfo("Assets:Bank:Example"))
        XCTAssertNil(store.cardHints["Assets:Bank:Example"])
    }

    func testARenamedAccountKeepsItsCard() {
        let store = Store()
        var current = RepoConfig(); current.id = "cards-rename-" + UUID().uuidString; current.kind = .local
        store.cfg = current
        defer { CardVault.delete(ledger: current.id) }
        store.setCardInfo(card, for: "Assets:Bank:Old")
        store.renameInGrid("Assets:Bank:Old", to: "Assets:Bank:New")
        XCTAssertNil(store.cardInfo("Assets:Bank:Old"))
        XCTAssertEqual(store.cardInfo("Assets:Bank:New"), card)
        XCTAssertEqual(store.cardTail("Assets:Bank:New"), "1111")
    }
}
