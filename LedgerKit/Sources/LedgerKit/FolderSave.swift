import Foundation

/// a new entry worked out against a folder on this computer, nothing written yet; `issues` are what it would break
public struct FolderSave {
    public let issues: [ChangeIssue]
    let main: String
    let files: [(path: String, before: String?, after: String)]
}

public struct FolderSaveError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

/// The phone's writing path without its queue: draftIssue → draftText (formatTxn, orderedPostings) → makeOps → applyOps →
/// reviewChange, on the files as they are now. An earlier read of the folder isn't trusted: anything may have changed it.
public func prepareFolderSave(_ draft: Draft, folder: URL) -> Result<FolderSave, FolderSaveError> {
    guard let ledger = loadLedger(folder: folder) else { return .failure(FolderSaveError(message: tr("这个文件夹里没有账本", "No ledger in this folder"))) }
    let derived = Derived(ledger)
    if let issue = draftIssue(draft, ledger, derived) { return .failure(FolderSaveError(message: issue.message)) }
    let text = draftText(draft, ledger, derived).trimmingCharacters(in: .whitespacesAndNewlines)
    let layout = folderLayout(ledger, folder: folder)
    let exists = { (path: String) in FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) }
    let ops: [Op]
    switch makeOps(text, ledger, layout: layout, pending: [], fileExists: exists, single: draftIsSingle(draft, ledger)) {
    case .success(let made): ops = made
    case .failure(let error): return .failure(FolderSaveError(message: error.message))
    }
    var paths: [String] = []
    for op in ops where !paths.contains(op.path) { paths.append(op.path) }
    do {
        var files: [(path: String, before: String?, after: String)] = []
        for path in paths {
            let before = exists(path) ? try coordinatedRead(folder.appendingPathComponent(path)) : nil
            files.append((path, before, try applyOps(before ?? "", path: path, ops: ops, strict: true)))
        }
        let written = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.after) })
        let after = loadLedger(root: layout.main, listFiles: { folderFiles(folder) + Array(written.keys) }) { path in
            try written[path] ?? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
        }
        return .success(FolderSave(issues: reviewChange(before: ledger, after: after), main: layout.main, files: files))
    } catch {
        return .failure(FolderSaveError(message: error.localizedDescription))
    }
}

/// Writes it, unless a file has changed since it was worked out. The main file goes last: if a write fails on the way,
/// the most that is left behind is a new file nothing includes yet.
public func commitFolderSave(_ save: FolderSave, folder: URL) throws {
    for file in save.files {
        let url = folder.appendingPathComponent(file.path)
        let now = FileManager.default.fileExists(atPath: url.path) ? try coordinatedRead(url) : nil
        guard now == file.before else {
            throw FolderSaveError(message: tr("\(file.path) 刚被改动过，请再保存一次", "\(file.path) has just changed: save again"))
        }
    }
    for file in save.files.sorted(by: { $0.path != save.main && $1.path == save.main }) {
        try coordinatedWrite(folder.appendingPathComponent(file.path), file.after)
    }
}

/// ledger-x.json first, then what the ledger looks like (as the phone's Store does, without its settings)
private func folderLayout(_ ledger: Ledger, folder: URL) -> RepoLayout {
    let config = ledgerConfig(folder: folder) ?? LedgerXConfig()
    let main = folderMain(folder)
    var layout = RepoLayout(main: main, journal: config.file(.transactions) ?? RepoLayout.detect(ledger, main: main).journal,
                            subscriptions: config.file(.subscriptions))
    for kind in LayoutKind.allCases { if let file = config.file(kind) { layout.files[kind] = file } }
    layout.rules = config.rules
    return layout
}

private func coordinatedRead(_ url: URL) throws -> String {
    var coordination: NSError?
    var result: Result<String, Error>?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { readable in
        result = Result { try String(contentsOf: readable, encoding: .utf8) }
    }
    if let coordination { throw coordination }
    return try result?.get() ?? ""
}

private func coordinatedWrite(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var coordination: NSError?
    var failure: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { writable in
        do { try Data(text.utf8).write(to: writable, options: .atomic) } catch { failure = error }
    }
    if let error = coordination ?? failure { throw error }
}
