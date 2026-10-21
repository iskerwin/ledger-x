import Foundation

/// The text of a save confirmation. The balance line is part of this first string,
/// so a toast does not appear and then change.
public func saveConfirmation(_ message: String, balance: String?) -> String {
    guard let balance, !balance.isEmpty else { return message }
    return message + "\n" + balance
}
