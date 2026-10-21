import Foundation
import LedgerKit

extension ImportChoice {
    init(_ item: ImportItem) {
        self.init(id: item.id, include: item.include, account: item.account, funding: item.funding, manual: item.manual)
    }
}

struct ImportCheckpoint: Codable {
    var ledgerID: String
    var fileName: String
    var source: ImportSource
    var columns: ImportColumns
    var defaultFunding: String
    var keepOrder: Bool
    var choices: [ImportChoice]
}
