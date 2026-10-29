import Foundation

/// Coming back to the app fetches the ledger again only when the last fetch is a minute old or more, or there is
/// something waiting to be sent: switching to another app and straight back used to fetch every time.
public enum ReturnRefresh {
    public static let interval: TimeInterval = 60

    public static func due(lastSync: Date?, now: Date, waiting: Bool) -> Bool {
        guard !waiting, let last = lastSync else { return true }
        return now.timeIntervalSince(last) >= interval || now < last
    }
}
