import Foundation
import LedgerKit

// A refund and the purchase it refunds share a link (^refund-…). Editing or deleting one of the pair
// must change the other the same way, or the two drift apart.

extension Store {
    /// the links (without ^) in a transaction's text
    func linksIn(_ text: String) -> [String] { linksOnHeader(text) }

    /// the refund link that should go on the original purchase, taken from the text actually saved
    func refundLink(in text: String, preferred: String) -> String? {
        refundLinkName(in: text, preferred: preferred)
    }

    /// ops that rename or remove a refund link on the other transaction of the pair, when this
    /// transaction (`oldText`) is edited into `newText` or deleted (`newText` nil)
    func pairedLinkOps(oldText: String, newText: String?) -> [Op] {
        guard let L = L else { return [] }
        return LedgerKit.pairedLinkOps(L, oldText: oldText, newText: newText)
    }
}
