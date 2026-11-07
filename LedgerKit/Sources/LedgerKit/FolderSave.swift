import Foundation

/// a new entry worked out against a folder on this computer, nothing written yet; `issues` are what it would break
public struct FolderSave {
    public let issues: [ChangeIssue]
    let main: String
    /// in the order they are written
    let files: [(path: String, before: String?, after: String)]
}

public struct FolderSaveError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

/// The phone's writing path without its queue: draftIssue → draftText (formatTxn, orderedPostings) → makeOps → applyOps →
/// reviewChange, on the files as they are now. An earlier read of the folder isn't trusted: anything may have changed it.
/// A draft with `replacing` changes that entry, which must still be there and be told apart from any copy of it.
public func prepareFolderSave(_ draft: Draft, folder: URL) -> Result<FolderSave, FolderSaveError> {
    guard let ledger = loadLedger(folder: folder) else { return .failure(noLedgerInFolder) }
    let derived = Derived(ledger)
    if let issue = draftIssue(draft, ledger, derived) { return .failure(FolderSaveError(message: issue.message)) }
    let text = draftText(draft, ledger, derived).trimmingCharacters(in: .whitespacesAndNewlines)
    let layout = folderLayout(ledger, folder: folder)
    let exists = { (path: String) in FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) }
    var replaced: [Op] = []
    var replacedDate: String?
    if let target = draft.replacing {
        let originals = parseFile(target.old, file: target.path).entries
        guard originals.count == 1, let entry = locate(originals[0], startLine: target.line.map { $0 - 1 }, folder: folder) else {
            return .failure(entryChanged)
        }
        if text == target.baseline { return .success(FolderSave(issues: [], main: layout.main, files: [])) }
        replaced = [entryOp(entry, text: nil)]
        replacedDate = entry.date
    }
    var ops: [Op]
    switch makeOps(text, ledger, layout: layout, pending: [], fileExists: exists, single: draftIsSingle(draft, ledger)) {
    case .success(let made): ops = made
    case .failure(let error): return .failure(FolderSaveError(message: error.message))
    }
    // the same day in the same file stays where it is; anything else moves to the end of its new day
    if let remove = replaced.first, ops.count == 1, ops[0].kind == .insert, ops[0].path == remove.path, ops[0].date == replacedDate {
        var replace = remove
        replace.kind = .replace
        replace.text = ops[0].text
        ops = [replace]
    } else {
        ops = replaced + ops
    }
    return folderSave(ops, before: ledger, main: layout.main, folder: folder)
}

/// the form for changing `entry` on this computer, or nil when the sheet can't show all of it. Its links stay as they are,
/// so the other side of a link needs nothing.
public func folderEditDraft(_ entry: Entry, _ ledger: Ledger, _ derived: Derived) -> Draft? {
    guard var draft = editDraft(entry, ledger, derived), [.expense, .income, .transfer, .refund].contains(draft.kind),
          !draft.reimb, !draft.split, draft.shares.isEmpty, draft.extraFunds.isEmpty, draft.discount.isEmpty, !draft.byRate,
          draft.kind == .transfer || (draft.feeMode == nil && (draft.transferFee ?? "").isEmpty), draft.paid.isEmpty, draft.refundOf == nil, draft.refundFee == nil,
          !draft.topup else { return nil }
    let summary = [entry.payee, entry.narration].filter { !$0.isEmpty }.joined(separator: " ")
    draft.replacing = Replacing(path: entry.file, old: entry.src, date: entry.date, summary: summary,
                                baseline: draftText(draft, ledger, derived).trimmingCharacters(in: .whitespacesAndNewlines), line: entry.line)
    return draft
}

/// Deleting `entry`, under the same checks as saving one. As on the phone, the other of a refund's pair loses the link they shared.
public func prepareFolderDelete(_ entry: Entry, folder: URL) -> Result<FolderSave, FolderSaveError> {
    guard let ledger = loadLedger(folder: folder) else { return .failure(noLedgerInFolder) }
    guard let current = locate(entry, startLine: nil, folder: folder) else { return .failure(entryChanged) }
    return folderSave([entryOp(current, text: nil)] + pairedLinkOps(ledger, oldText: current.src, newText: nil), before: ledger, main: folderMain(folder), folder: folder)
}

/// That `account` ended `day` with `amount`. Beancount checks an assertion at the start of its day, so it is dated the next one.
/// Refused, with the difference, when the ledger says otherwise: the entries are put right first, as on the phone.
public func prepareFolderBalance(account: String, day: String, amount: Double, currency: String, folder: URL) -> Result<FolderSave, FolderSaveError> {
    guard let ledger = loadLedger(folder: folder) else { return .failure(noLedgerInFolder) }
    let date = Day.shift(day, 1)
    guard existingBalance(ledger, account: account, date: date, currency: currency) == nil else {
        return .failure(FolderSaveError(message: tr("这天已有余额断言，没有写入", "This day already has a balance assertion: nothing was written")))
    }
    let layout = folderLayout(ledger, folder: folder)
    let exists = { (path: String) in FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) }
    switch makeOps(balanceLine(date, account, amount, currency), ledger, layout: layout, pending: [], fileExists: exists, single: false) {
    case .failure(let error): return .failure(FolderSaveError(message: error.message))
    case .success(let ops):
        let prepared = folderSave(ops, before: ledger, main: layout.main, folder: folder)
        if case .success(let save) = prepared, let issue = save.issues.first {
            return .failure(FolderSaveError(message: issue.detail.isEmpty ? issue.title : issue.detail))
        }
        return prepared
    }
}

private let noLedgerInFolder = FolderSaveError(message: tr("这个文件夹里没有账本", "No ledger in this folder"))
private let entryChanged = FolderSaveError(message: tr("原来的交易已经变了，没有改动", "The entry has changed: nothing was changed"))

/// the entry as it is in its file now; nil when it's gone, or when several copies can't be told apart
private func locate(_ entry: Entry, startLine: Int?, folder: URL) -> Entry? {
    guard let text = try? coordinatedRead(folder.appendingPathComponent(entry.file)) else { return nil }
    return EntryLocator(entry, startLine: startLine).resolve(in: parseFile(text, file: entry.file).entries)
}

private func folderSave(_ ops: [Op], before ledger: Ledger, main: String, folder: URL) -> Result<FolderSave, FolderSaveError> {
    let exists = { (path: String) in FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) }
    // new files, then the main file that includes them, and what an entry leaves last: stopped on the way,
    // the most left behind is an unused file or an entry in two places, and nothing lost
    let removing = Set(ops.filter { $0.kind == .remove }.map(\.path))
    var paths: [String] = []
    for op in ops where !paths.contains(op.path) { paths.append(op.path) }
    let rank = { (path: String) in removing.contains(path) ? 2 : path == main ? 1 : 0 }
    paths = paths.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    do {
        var files: [(path: String, before: String?, after: String)] = []
        for path in paths {
            let before = exists(path) ? try coordinatedRead(folder.appendingPathComponent(path)) : nil
            files.append((path, before, try applyOps(before ?? "", path: path, ops: ops, strict: true)))
        }
        let written = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.after) })
        let after = loadLedger(root: main, listFiles: { folderFiles(folder) + Array(written.keys) }) { path in
            try written[path] ?? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
        }
        return .success(FolderSave(issues: reviewChange(before: ledger, after: after), main: main, files: files))
    } catch {
        return .failure(FolderSaveError(message: error.localizedDescription))
    }
}

/// Writes it, unless a file has changed since it was worked out.
public func commitFolderSave(_ save: FolderSave, folder: URL) throws {
    for file in save.files {
        let url = folder.appendingPathComponent(file.path)
        let now = FileManager.default.fileExists(atPath: url.path) ? try coordinatedRead(url) : nil
        guard now == file.before else {
            throw FolderSaveError(message: tr("\(file.path) 刚被改动过，请再保存一次", "\(file.path) has just changed: save again"))
        }
    }
    for file in save.files {
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
