import Foundation
import LedgerKit

/// 卡片信息: each ledger's cards (number, expiry, security code, holder) in this phone's keychain, one item per
/// ledger, kept to this phone (`Keychain.save`). Never in the ledger, the settings or a backup.
enum CardVault {
    static func key(_ ledger: String) -> String { "cards." + ledger }

    static func load(ledger: String) -> [String: CardInfo] {
        guard let s = Keychain.load(account: key(ledger)), let d = s.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: CardInfo].self, from: d)) ?? [:]
    }

    /// false: the keychain (and the protected file it falls back to) did not take it
    @discardableResult
    static func save(_ cards: [String: CardInfo], ledger: String) -> Bool {
        let kept = cards.filter { !$0.value.isEmpty }
        guard !kept.isEmpty else { delete(ledger: ledger); return true }
        guard let d = try? JSONEncoder().encode(kept) else { return false }
        return Keychain.save(String(decoding: d, as: UTF8.self), account: key(ledger))
    }

    static func delete(ledger: String) { Keychain.delete(account: key(ledger)) }

    /// what the card's face shows without asking: the last four digits and the expiry
    static func hints(_ cards: [String: CardInfo]) -> [String: CardHint] {
        cards.compactMapValues { c in
            let h = CardHint(last4: c.last4, expiry: c.expiry.isEmpty ? nil : c.expiry)
            return h.last4 == nil && h.expiry == nil ? nil : h
        }
    }
}

struct CardHint: Equatable {
    var last4: String?
    var expiry: String?
}

extension Store {
    /// the card kept for an account, read from the keychain when it is to be shown or changed
    func cardInfo(_ account: String) -> CardInfo? { CardVault.load(ledger: cfg.id)[account] }

    /// an account's card changed (an empty one removed); false when the keychain did not take it
    @discardableResult
    func setCardInfo(_ info: CardInfo, for account: String) -> Bool {
        var all = CardVault.load(ledger: cfg.id)
        all[account] = info.isEmpty ? nil : info
        guard CardVault.save(all, ledger: cfg.id) else { return false }
        cardHints = CardVault.hints(all)
        return true
    }

    /// the last four digits on a card's face: the ledger's own (扫码记账's 尾号), else the number kept on this phone
    func cardTail(_ account: String) -> String? {
        repoConfig?.scanCards?.first { $0.value == account && $0.key.count == 4 && $0.key.allSatisfy(\.isNumber) }?.key
            ?? cardHints[account]?.last4
    }

    /// an account renamed or merged: its card goes along
    func renameCards(_ from: String, to: String) {
        let all = CardVault.load(ledger: cfg.id)
        let moved = renamedCardInfos(all, from: from, to: to)
        guard moved != all, CardVault.save(moved, ledger: cfg.id) else { return }
        cardHints = CardVault.hints(moved)
    }
}
