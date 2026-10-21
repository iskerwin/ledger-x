import Foundation
import LedgerKit

/// CSV/XLSX decoding can be expensive. Keep it off the main actor and discard cancelled requests.
actor BillLoader {
    static let shared = BillLoader()
    func read(_ data: Data, name: String, columns: ImportColumns?) -> ImportTable? {
        guard !Task.isCancelled else { return nil }
        let table = readBill(data, fileName: name, columns: columns)
        return Task.isCancelled ? nil : table
    }
}
