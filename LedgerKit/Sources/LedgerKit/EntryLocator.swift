import Foundation

/// An immutable source identity for an action kept open while a ledger refreshes.
/// Line numbers and parser IDs can change. Ambiguous duplicate entries must never be guessed.
public struct EntryLocator {
    public let file: String
    private let type: EntryType
    private let source: String
    private let writable: Bool

    public init(_ entry: Entry) {
        file = entry.file
        type = entry.type
        source = normEntryText(entry.src)
        writable = !entry.synthetic && !file.isEmpty && !source.isEmpty
    }

    public func resolve(in entries: [Entry]) -> Entry? {
        guard writable else { return nil }
        let matches = entries.filter {
            !$0.synthetic && $0.file == file && $0.type == type && normEntryText($0.src) == source
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Reparse the actual file, including pending changes, rather than trusting cached line offsets.
    public func text(in fileText: String) -> String? {
        resolve(in: parseFile(fileText, file: file).entries)?.src
    }
}
