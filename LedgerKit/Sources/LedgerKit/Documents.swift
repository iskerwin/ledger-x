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
