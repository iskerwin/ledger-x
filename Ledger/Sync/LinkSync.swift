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
        let oldLinks = Set(linksIn(oldText)), newLinks = Set(newText.map(linksIn) ?? [])
        let removed = oldLinks.subtracting(newLinks).filter { $0.hasPrefix("refund") }
        guard !removed.isEmpty else { return [] }
        let added = Array(newLinks.subtracting(oldLinks).filter { $0.hasPrefix("refund") })
        let me = oldText.trimmed
        var ops: [Op] = []
        for l in removed.sorted() {
            // only a pair: with several refunds sharing the link, the others still need it
            let others = L.txns.filter { $0.links.contains(l) && !$0.synthetic && $0.src.trimmed != me }
            guard others.count == 1, let p = others.first else { continue }
            var op = entryOp(p, text: headerLinkReplace(p.src, link: l, with: added.count == 1 ? added[0] : nil))
            op.silent = true
            ops.append(op)
        }
        return ops
    }
}
