import Foundation

/// Resolve a document relative to its directive, without escaping the ledger folder.
public func documentPath(_ path: String, from file: String) -> String? {
    guard !path.isEmpty else { return nil }
    var path = path
    if path.hasPrefix("/") {
        guard let range = path.range(of: "/documents/") else { return nil }
        path = String(path[path.index(after: range.lowerBound)...])
        return documentPath(path, from: "main.bean")
    }
    var parts = (file as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
    for part in path.split(separator: "/") {
        if part == ".." {
            guard !parts.isEmpty else { return nil }
            parts.removeLast()
        } else if part != "." { parts.append(String(part)) }
    }
    return parts.isEmpty ? nil : parts.joined(separator: "/")
}

/// A repository path relative to the directive's file.
public func relativeDocumentPath(_ path: String, from file: String) -> String {
    let base = (file as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
    let target = path.split(separator: "/").map(String.init)
    var shared = 0
    while shared < base.count && shared < target.count && base[shared] == target[shared] { shared += 1 }
    return (Array(repeating: "..", count: base.count - shared) + Array(target.dropFirst(shared))).joined(separator: "/")
}

public func documentText(date: String, account: String, path: String) -> String {
    "\(date) document \(account) \(quoted(path))"
}

/// Why a single folder or file name cannot be used under `documents/`.
public enum DocumentNameIssue: Equatable {
    case empty
    case separator
    case reserved
}

/// A path segment: non-empty after trimming, no slash, backslash or control character, and not `.` or `..`.
public func documentNameIssue(_ raw: String) -> DocumentNameIssue? {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return .empty }
    if name == "." || name == ".." { return .reserved }
    if name.contains("/") || name.contains("\\") || name.contains("\"") || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
        return .separator
    }
    return nil
}

/// Institution folder for an account's documents. Flat, one level, lowercased.
/// Assets and Liabilities with at least three parts use the third part, so a bank
/// account and that bank's card share a folder (`Assets:Bank:DemoBank:Cash` and
/// `Liabilities:CreditCard:DemoBank` are both `demobank`). Two-part asset or
/// liability names, and every other account, use the last part (`Assets:Cash` → `cash`,
/// `Expenses:Food:Demo` → `demo`). An unusable part yields an empty string.
public func documentFolder(for account: String) -> String {
    let parts = account.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    guard !parts.isEmpty else { return "" }
    let root = parts[0].lowercased()
    let raw = (root == "assets" || root == "liabilities") && parts.count >= 3 ? parts[2] : parts[parts.count - 1]
    let name = raw.lowercased()
    return documentNameIssue(name) == nil ? name : ""
}

/// `YYYY-MM-DD` or `YYYYMMDD` → `YYYYMMDD`. Anything else is empty.
public func documentDateStamp(_ date: String) -> String {
    let parts = date.split(separator: "-").map(String.init)
    if parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
       parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
        return parts.joined()
    }
    if date.count == 8, date.allSatisfy(\.isNumber) { return date }
    return ""
}

/// Letters and digits only, lowercased. `PDF` and `jp g` both become a safe suffix.
public func normalizedDocumentExtension(_ ext: String) -> String {
    ext.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
}

public func documentFileName(stem: String, ext: String) -> String {
    let stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
    let ext = normalizedDocumentExtension(ext)
    guard !ext.isEmpty else { return stem }
    return stem + "." + ext
}

public func documentFileStem(_ fileName: String, ext: String) -> String {
    let ext = normalizedDocumentExtension(ext)
    guard !ext.isEmpty else { return fileName }
    let suffix = "." + ext
    if fileName.lowercased().hasSuffix(suffix) { return String(fileName.dropLast(suffix.count)) }
    return fileName
}

/// `documents/<folder>/<folder>_YYYYMMDD.<ext>`, or `_1`, `_2`, … when that path is already in `existingPaths`.
public func preferredDocumentFileName(folder: String, date: String, ext: String, existingPaths: Set<String>) -> String {
    let folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
    guard documentNameIssue(folder) == nil else { return "" }
    let stamp = documentDateStamp(date)
    guard !stamp.isEmpty else { return "" }
    let ext = normalizedDocumentExtension(ext)
    let base = folder + "_" + stamp
    func candidate(_ n: Int) -> String {
        let stem = n == 0 ? base : base + "_" + String(n)
        return ext.isEmpty ? stem : stem + "." + ext
    }
    var n = 0
    var name = candidate(n)
    while existingPaths.contains("documents/\(folder)/\(name)") {
        n += 1
        name = candidate(n)
    }
    return name
}

/// `documents/<folder>/<file>` when both segments are usable.
public func documentStoragePath(folder: String, fileName: String) -> String? {
    let folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
    let fileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard documentNameIssue(folder) == nil, documentNameIssue(fileName) == nil else { return nil }
    return "documents/\(folder)/\(fileName)"
}

/// The account a transaction's document is filed under, and named on the document directive.
/// The Assets or Liabilities posting that pays (a negative amount). On a transfer that is the From side.
/// When several accounts pay, the one that pays the most is used; a tie keeps the earlier posting.
/// Income and refunds have no paying posting, so the first Assets or Liabilities account is used.
public func documentPayingAccount(_ postings: [Posting]) -> String {
    let held = postings.filter { posting in
        let root = posting.account.split(separator: ":", maxSplits: 1).first.map { String($0).lowercased() }
        return root == "assets" || root == "liabilities"
    }
    let paying = held.filter { ($0.units ?? 0) < -EPS }
    if let payer = paying.min(by: { ($0.units ?? 0) < ($1.units ?? 0) }) { return payer.account }
    if let first = held.first { return first.account }
    return postings.first?.account ?? ""
}

/// First segment under `documents/` that already contains a file. A file sitting directly in `documents/` is not a folder.
public func documentFolders<S: Sequence>(in paths: S) -> [String] where S.Element == String {
    var names = Set<String>()
    for path in paths {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "documents" else { continue }
        let folder = parts[1]
        guard documentNameIssue(folder) == nil else { continue }
        names.insert(folder)
    }
    return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

/// Where a transaction's attachment is saved by default. Account statements go to the institution's folder
/// (`documentFolder(for:)`); attachments stay apart from them.
public let transactionAttachmentFolder = "receipts"

/// Documents that share a link with a transaction (`^doc-…` on both): that transaction's attachments,
/// newest first. Everything else is an account's own statement. Read from the link, not the folder,
/// so attachments saved before `receipts/` existed are sorted the same way.
public func transactionAttachments(_ L: Ledger) -> [Entry] {
    let linked = Set(L.txns.lazy.filter { !$0.synthetic }.flatMap { $0.links })
    return L.documents.filter { !linked.isDisjoint(with: $0.links) }.sorted { $0.date > $1.date }
}
