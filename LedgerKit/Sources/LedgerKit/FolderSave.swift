import Foundation

/// a new entry worked out against a folder on this computer, nothing written yet; `issues` are what it would break
public struct FolderSave {
    public let issues: [ChangeIssue]
    let main: String
    /// in the order they are written
    let files: [(path: String, before: String?, after: String)]
    /// new files that aren't text (a statement, a receipt), written first: stopped after them, the most left behind is a
    /// file nothing points at yet
    var blobs: [(path: String, data: Data)] = []
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
    let derived = folderDerived(ledger, config: ledgerConfig(folder: folder))
    if let issue = draftIssue(draft, ledger, derived) { return .failure(FolderSaveError(message: issue.message)) }
    let typed = draftText(draft, ledger, derived).trimmingCharacters(in: .whitespacesAndNewlines)
    let text = draft.kind == .raw ? alignText(typed) : typed
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
    let replacedBalances = draft.kind == .raw ? duplicateBalances(validateText(text, ledger, single: false).entries, ledger) : []
    return folderSave(ops, before: ledger, main: layout.main, folder: folder).map { save in
        guard !replacedBalances.isEmpty else { return save }
        let detail = replacedBalances.map { "\($0.date) \($0.account ?? "")" }.joined(separator: "\n")
        let issue = ChangeIssue(kind: .balance, title: tr("同一天已有余额断言", "That day already has a balance assertion"), detail: detail)
        return FolderSave(issues: [issue] + save.issues, main: save.main, files: save.files)
    }
}

/// what the forms need, with the account advances wait in as ledger-x.json says, as on the phone
public func folderDerived(_ ledger: Ledger, config: LedgerXConfig?) -> Derived {
    guard let receivable = config?.receivable?.trimmingCharacters(in: .whitespaces), !receivable.isEmpty else { return Derived(ledger) }
    return Derived(ledger, receivable: receivable)
}

/// the form for changing `entry` on this computer, or nil when no form can hold all of it (then only its source can change).
/// Its links stay as they are, so the other side of a link needs nothing.
public func folderEditDraft(_ entry: Entry, _ ledger: Ledger, _ derived: Derived) -> Draft? {
    guard var draft = editDraft(entry, ledger, derived) else { return nil }
    let summary = [entry.payee, entry.narration].filter { !$0.isEmpty }.joined(separator: " ")
    draft.replacing = Replacing(path: entry.file, old: entry.src, date: entry.date, summary: summary,
                                baseline: draftText(draft, ledger, derived).trimmingCharacters(in: .whitespacesAndNewlines), line: entry.line)
    return draft
}

/// `entry`'s source as text to change, on the same writing path: saved unchanged it writes nothing, and changed it replaces
/// that entry alone. Any entry can be changed this way, whether or not a form can hold it.
public func folderSourceDraft(_ entry: Entry) -> Draft {
    var draft = Draft()
    draft.kind = .raw
    draft.date = entry.date
    draft.raw = entry.src.trimmingCharacters(in: .whitespacesAndNewlines)
    let summary = [entry.payee, entry.narration].filter { !$0.isEmpty }.joined(separator: " ")
    draft.replacing = Replacing(path: entry.file, old: entry.src, date: entry.date, summary: summary, baseline: alignText(draft.raw), line: entry.line)
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
    let prepared = folderDirective(balanceLine(date, account, amount, currency), ledger, folder: folder)
    if case .success(let save) = prepared, let issue = save.issues.first {
        return .failure(FolderSaveError(message: issue.detail.isEmpty ? issue.title : issue.detail))
    }
    return prepared
}

/// `commodity <currency>`, what check_commodity asks for, dated like the declarations already there (else the day the
/// currency was first used), as the phone's 补上声明 writes it
public func prepareFolderCommodity(_ currency: String, firstUsed: String?, folder: URL) -> Result<FolderSave, FolderSaveError> {
    guard let ledger = loadLedger(folder: folder) else { return .failure(noLedgerInFolder) }
    let date = ledger.entries.filter { $0.type == .commodity }.map(\.date).min() ?? firstUsed ?? Day.today()
    return folderDirective("\(date) commodity \(currency)", ledger, folder: folder)
}

/// a line of its own (an assertion, a declaration), put where its kind goes
private func folderDirective(_ text: String, _ ledger: Ledger, folder: URL) -> Result<FolderSave, FolderSaveError> {
    let layout = folderLayout(ledger, folder: folder)
    let exists = { (path: String) in FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) }
    switch makeOps(text, ledger, layout: layout, pending: [], fileExists: exists, single: false) {
    case .failure(let error): return .failure(FolderSaveError(message: error.message))
    case .success(let ops): return folderSave(ops, before: ledger, main: layout.main, folder: folder)
    }
}

/// A statement, or any file, kept with `account`, as the phone's 添加票据 / 对账单: the file goes to the institution's
/// folder under documents/, named for its day, and a `document` line points at it
public func prepareFolderStatement(account: String, date: String, data: Data, ext: String, folder: URL) -> Result<FolderSave, FolderSaveError> {
    guard let ledger = loadLedger(folder: folder) else { return .failure(noLedgerInFolder) }
    guard let path = newDocumentPath(documentFolder(for: account), date: date, ext: ext, ledger, folder: folder) else { return .failure(unusableName) }
    return folderDocument(documentText(date: date, account: account, path: path), path: path, data: data, ledger, folder: folder)
}

/// A receipt or other file attached to `entry`, as the phone's 添加附件: the file goes to documents/receipts/, filed under
/// the account that paid, and the entry and the `document` line share a ^doc- link (the entry's own, when it has one)
public func prepareFolderAttachment(_ entry: Entry, data: Data, ext: String, folder: URL) -> Result<FolderSave, FolderSaveError> {
    guard let ledger = loadLedger(folder: folder) else { return .failure(noLedgerInFolder) }
    guard let current = locate(entry, startLine: entry.line - 1, folder: folder),
          let text = try? coordinatedRead(folder.appendingPathComponent(current.file)) else { return .failure(entryChanged) }
    let account = documentPayingAccount(current.postings)
    guard !account.isEmpty else { return .failure(FolderSaveError(message: tr("这笔交易没有付款账户，不能添加附件", "This entry has no paying account to file the attachment under"))) }
    guard let path = newDocumentPath(transactionAttachmentFolder, date: current.date, ext: ext, ledger, folder: folder) else { return .failure(unusableName) }
    let link = current.links.first { $0.hasPrefix("doc-") }
        ?? "doc-" + documentDateStamp(current.date) + "-" + UUID().uuidString.prefix(8).lowercased()
    var linking: [Op] = []
    if !current.links.contains(link) {
        let lines = text.components(separatedBy: "\n")
        guard current.startLine >= 0, current.startLine < lines.count else { return .failure(entryChanged) }
        var op = Op(kind: .link, path: current.file)
        op.headerLine = current.startLine + 1
        op.header = lines[current.startLine]
        op.add = " ^" + link
        op.link = link
        op.silent = true
        linking = [op]
    }
    return folderDocument(documentText(date: current.date, account: account, path: path) + " ^" + link, path: path, data: data, ledger,
                          folder: folder, also: linking)
}

/// what deleting a document did with its file
public enum DocumentFileOutcome: Equatable {
    /// left where it is, as asked
    case kept
    /// left where it is: this many other lines still point at it
    case inUse(Int)
    /// in the Trash, where it can still be put back
    case trashed
    /// it wasn't there
    case missing
}

/// A document's line removed, as the phone's 删除 does: with `file`, its file goes to the Trash as well, unless another
/// line still points at it. The line goes first: stopped between the two, the most left behind is a file nothing points at.
public func deleteFolderDocument(_ entry: Entry, file: Bool, folder: URL) throws -> DocumentFileOutcome {
    guard entry.type == .document, !entry.synthetic else { throw entryChanged }
    let save = try prepareFolderDelete(entry, folder: folder).get()
    let path = entry.path.flatMap { documentPath($0, from: entry.file) }
    let others = file && path != nil ? loadLedger(folder: folder).map { ledger in
        documentReferences(ledger, path: path!).filter { !($0.file == entry.file && $0.line == entry.line) }.count
    } ?? 0 : 0
    try commitFolderSave(save, folder: folder)
    guard file, let path else { return .kept }
    if others > 0 { return .inUse(others) }
    let url = folder.appendingPathComponent(path)
    guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
    do {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    } catch {
        throw FolderSaveError(message: tr("记录已移除，文件没能移到废纸篓：\(error.localizedDescription)",
                                          "The record is gone, but the file couldn't go to the Trash: \(error.localizedDescription)"))
    }
    return .trashed
}

/// `documents/<box>/<box>_YYYYMMDD.<ext>`, numbered past what's in the folder and what the ledger already points at
private func newDocumentPath(_ box: String, date: String, ext: String, _ ledger: Ledger, folder: URL) -> String? {
    let dir = folder.appendingPathComponent("documents/" + box)
    let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { "documents/\(box)/\($0)" }
    let taken = Set(onDisk + ledger.documents.compactMap { d in d.path.flatMap { documentPath($0, from: d.file) } })
    let name = preferredDocumentFileName(folder: box, date: date, ext: ext, existingPaths: taken)
    return name.isEmpty ? nil : documentStoragePath(folder: box, fileName: name)
}

/// the `document` line put where its kind goes, its path written from that file, with the file itself to write first
private func folderDocument(_ line: String, path: String, data: Data, _ ledger: Ledger, folder: URL, also: [Op] = []) -> Result<FolderSave, FolderSaveError> {
    let layout = folderLayout(ledger, folder: folder)
    let exists = { (path: String) in FileManager.default.fileExists(atPath: folder.appendingPathComponent(path).path) }
    guard !exists(path) else { return .failure(nameTaken) }
    switch makeOps(line, ledger, layout: layout, pending: [], fileExists: exists, single: false) {
    case .failure(let error): return .failure(FolderSaveError(message: error.message))
    case .success(var ops):
        for i in ops.indices where ops[i].kind == .insert {
            ops[i].text = ops[i].text?.replacingOccurrences(of: quoted(path), with: quoted(relativeDocumentPath(path, from: ops[i].path)))
        }
        return folderSave(ops + also, before: ledger, main: layout.main, folder: folder, blobs: [(path, data)])
    }
}

private let unusableName = FolderSaveError(message: tr("这个日期或文件类型不能用作文件名", "That day or file type can't name a file"))
private let nameTaken = FolderSaveError(message: tr("这个文件已经在账本里，请再试一次", "That file is already in the ledger: try again"))
private let noLedgerInFolder = FolderSaveError(message: tr("这个文件夹里没有账本", "No ledger in this folder"))
private let entryChanged = FolderSaveError(message: tr("原来的交易已经变了，没有改动", "The entry has changed: nothing was changed"))

/// the entry as it is in its file now; nil when it's gone, or when several copies can't be told apart
private func locate(_ entry: Entry, startLine: Int?, folder: URL) -> Entry? {
    guard let text = try? coordinatedRead(folder.appendingPathComponent(entry.file)) else { return nil }
    return EntryLocator(entry, startLine: startLine).resolve(in: parseFile(text, file: entry.file).entries)
}

private func folderSave(_ ops: [Op], before ledger: Ledger, main: String, folder: URL, blobs: [(path: String, data: Data)] = []) -> Result<FolderSave, FolderSaveError> {
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
        return .success(FolderSave(issues: reviewChange(before: ledger, after: after), main: main, files: files, blobs: blobs))
    } catch {
        return .failure(FolderSaveError(message: error.localizedDescription))
    }
}

/// ledger-x.json changed as `change` says, written as the phone writes it; nothing when it comes out the same.
/// A file that doesn't read as one isn't written over.
public func prepareFolderConfig(folder: URL, _ change: (inout LedgerXConfig) -> Void) -> Result<FolderSave, FolderSaveError> {
    let url = folder.appendingPathComponent(LedgerXConfig.path)
    let before = try? coordinatedRead(url)
    var config = LedgerXConfig()
    if let before {
        guard let read = LedgerXConfig.parse(before) else {
            return .failure(FolderSaveError(message: tr("\(LedgerXConfig.path) 读不出来，没有写入", "\(LedgerXConfig.path) can't be read: nothing was written")))
        }
        config = read
    }
    let unchanged = config
    change(&config)
    guard config != unchanged else { return .success(FolderSave(issues: [], main: folderMain(folder), files: [])) }
    return .success(FolderSave(issues: [], main: folderMain(folder), files: [(LedgerXConfig.path, before, config.json())]))
}

/// Writes it, unless a file has changed since it was worked out.
public func commitFolderSave(_ save: FolderSave, folder: URL) throws {
    for blob in save.blobs where FileManager.default.fileExists(atPath: folder.appendingPathComponent(blob.path).path) {
        throw FolderSaveError(message: tr("\(blob.path) 已经有了，没有写入", "\(blob.path) is already there: nothing was written"))
    }
    for file in save.files {
        let url = folder.appendingPathComponent(file.path)
        let now = FileManager.default.fileExists(atPath: url.path) ? try coordinatedRead(url) : nil
        guard now == file.before else {
            throw FolderSaveError(message: tr("\(file.path) 刚被改动过，请再保存一次", "\(file.path) has just changed: save again"))
        }
    }
    for blob in save.blobs {
        let url = folder.appendingPathComponent(blob.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try blob.data.write(to: url, options: .withoutOverwriting)
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
