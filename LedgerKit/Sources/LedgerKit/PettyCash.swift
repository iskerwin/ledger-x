import Foundation

/// Money received in advance is a negative reimbursement receivable, grouped by its own float link.
public func pettyCashText(date: String, company: String, amount: Double, currency: String,
                          account: String, receivable: String, link: String, note: String = "") -> String {
    guard amount.isFinite, roundMoney(amount, 2) > 0, !company.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !account.isEmpty, account != receivable, isFloatLink(link), isValidTag(link) else { return "" }
    var tx = TxDraft(date: date)
    tx.payee = company.trimmingCharacters(in: .whitespacesAndNewlines)
    tx.narration = note.isEmpty ? tr("领取备用金", "Petty cash received") : note
    tx.links = [link]
    let value = roundMoney(amount, 2)
    tx.postings = [TxPosting(account: receivable, amount: -value, currency: currency),
                   TxPosting(account: account, amount: value, currency: currency)]
    return formatTxn(tx)
}
