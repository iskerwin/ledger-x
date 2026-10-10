import Foundation
import LedgerKit

// A refund and the purchase it refunds share a link (^refund-…). Editing or deleting one of the pair
// must change the other the same way, or the two drift apart.

extension Store {
    /// the links (without ^) in a transaction's text
    func linksIn(_ text: String) -> [String] {
        let header = text.components(separatedBy: "\n").first { !$0.trimmed.isEmpty } ?? ""
        return header.split(separator: " ").filter { $0.hasPrefix("^") && $0.count > 1 }.map { String($0.dropFirst()) }
    }

    /// the refund link that should go on the original purchase, taken from the text actually saved
    func refundLink(in text: String, preferred: String) -> String? {
        let ls = linksIn(text).filter { $0.hasPrefix("refund") }
        if ls.contains(preferred) { return preferred }
        return ls.count == 1 ? ls[0] : nil
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
            var lines = p.src.components(separatedBy: "\n")
            guard !lines.isEmpty else { continue }
            var words = lines[0].components(separatedBy: " ")
            if added.count == 1 { words = words.map { $0 == "^" + l ? "^" + added[0] : $0 } }
            else { words.removeAll { $0 == "^" + l } }
            lines[0] = words.joined(separator: " ")
            var op = Op(kind: .replace, path: p.file)
            op.old = p.src
            op.text = lines.joined(separator: "\n")
            op.date = p.date
            op.silent = true
            ops.append(op)
        }
        return ops
    }
}
