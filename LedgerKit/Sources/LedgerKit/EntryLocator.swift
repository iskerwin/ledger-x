import Foundation

/// An immutable source identity for an action kept open while a ledger refreshes.
/// Line numbers and parser IDs can change, so a single copy is found by its text even after lines shift.
/// Several copies with the same text are told apart only while one of them still starts on the remembered
/// line. If that line moved and more than one copy remains, nothing is guessed.
public struct EntryLocator {
    public let file: String
    private let type: EntryType
    private let source: String
    /// 0-based first line in `file`, used only when the text is not unique
    private let startLine: Int
    private let writable: Bool

    public init(_ entry: Entry, startLine: Int? = nil) {
        file = entry.file
        type = entry.type
        source = normEntryText(entry.src)
        self.startLine = startLine ?? entry.startLine
        writable = !entry.synthetic && !file.isEmpty && !source.isEmpty
    }

    public func resolve(in entries: [Entry]) -> Entry? {
        guard writable else { return nil }
        let matches = entries.filter {
            !$0.synthetic && $0.file == file && $0.type == type && normEntryText($0.src) == source
        }
        if matches.count == 1 { return matches[0] }
        let onLine = matches.filter { $0.startLine == startLine }
        return onLine.count == 1 ? onLine[0] : nil
    }

    /// Reparse the actual file, including pending changes, rather than trusting cached line offsets.
    public func text(in fileText: String) -> String? {
        resolve(in: parseFile(fileText, file: file).entries)?.src
    }
}
