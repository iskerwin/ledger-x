import Foundation

/// Editable open-directive fields, shared with the folder writer. Unmanaged metadata stays in the original directive.
public struct AccountForm: Equatable {
    public static let roots = ["Assets", "Liabilities", "Income", "Expenses", "Equity"]
    public static let bookings = ["", "STRICT", "FIFO", "LIFO", "HIFO", "AVERAGE", "NONE"]
    public var account: String
    public var date: String
    public var name = ""
    public var currencies = ""
    public var booking = ""
    /// A number, or a number and currency (the existing credit_limit metadata supports both).
    public var limit = ""
    public var statementDay = 0
    public var dueDay = 0
    public var allowNegative = false

    public init(account: String, date: String) { self.account = account; self.date = date }

    public init(_ account: Account, fallbackDate: String) {
        self.init(account: account.name, date: account.open ?? fallbackDate)
        name = account.meta["name"]?.stringValue ?? ""
        currencies = account.currencies.joined(separator: ",")
        booking = account.booking?.uppercased() ?? ""
        limit = account.meta[creditLimitKey].map { $0.stringValue ?? $0.display } ?? ""
        statementDay = account.meta[statementDayKey].flatMap { Int($0.stringValue ?? $0.display) } ?? 0
        dueDay = account.meta[dueDayKey].flatMap { Int($0.stringValue ?? $0.display) } ?? 0
        allowNegative = metaTrue(account.meta[allowNegativeKey])
    }

    public func directive(keeping original: String?) -> Result<String, FolderSaveError> {
        guard date.count == 10, dateAt(scalars(date), 0) == date, isCalendarDate(date) else {
            return .failure(FolderSaveError(message: tr("请输入有效的开立日期", "Enter a valid opening date")))
        }
        let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAccountName(account), Self.roots.contains(where: { account.hasPrefix($0 + ":") }) else {
            return .failure(FolderSaveError(message: tr("请输入有效的账户名，如 Assets:Bank:Example", "Enter a valid account name, such as Assets:Bank:Example")))
        }
        guard Self.bookings.contains(booking), (0...31).contains(statementDay), (0...31).contains(dueDay) else {
            return .failure(FolderSaveError(message: tr("请检查批次方法和每月日期", "Check the booking method and monthly days")))
        }
        let parts = limit.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var amount: Double?
        if account.hasPrefix("Liabilities:"), !parts.isEmpty {
            guard parts.count <= 2, let number = Double(parts[0].replacingOccurrences(of: ",", with: "")), number.isFinite, number > 0,
                  parts.count == 1 || currencyLength(scalars(parts[1]), 0) == scalars(parts[1]).count else {
                return .failure(FolderSaveError(message: tr("请输入有效的信用额度，如 50000 或 50000 CNY", "Enter a valid credit limit, such as 50000 or 50000 CNY")))
            }
            amount = number
        }
        let codes = currencies.uppercased().split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        guard Set(codes).count == codes.count, codes.allSatisfy({ currencyLength(scalars($0), 0) == scalars($0).count }) else {
            return .failure(FolderSaveError(message: tr("限定币种不能重复且必须是有效币种代码", "Allowed currencies must be valid currency codes without duplicates")))
        }
        let text = openDirectiveText(date: date, account: account, currencies: codes, booking: booking, name: name,
                                         creditLimit: amount, allowNegative: allowNegative, statementDay: statementDay, dueDay: dueDay,
                                         keep: original, creditLimitCurrency: parts.count == 2 ? parts[1] : nil)
        var lines = text.components(separatedBy: "\n")
        let header = scalars((original ?? "").components(separatedBy: "\n").first ?? "")
        let comment = str(header.dropFirst(stripComment(header).count))
        if !comment.isEmpty { lines[0] += " " + comment }
        return .success(lines.joined(separator: "\n"))
    }
}

/// Account management uses the same fresh read, layout, validation and optimistic file checks as entry editing.
public func prepareFolderAccount(_ form: AccountForm, replacing original: Entry?, folder: URL) -> Result<FolderSave, FolderSaveError> {
    guard let ledger = loadLedger(folder: folder) else { return .failure(FolderSaveError(message: tr("这个文件夹里没有账本", "No ledger in this folder"))) }
    let account = form.account.trimmingCharacters(in: .whitespacesAndNewlines)
    if let original {
        guard original.type == .open, original.account == account else {
            return .failure(FolderSaveError(message: tr("账户名的修改请使用重命名操作", "Use Rename to change an account name")))
        }
    } else if ledger.entries.contains(where: { $0.type == .open && $0.account == account }) {
        return .failure(FolderSaveError(message: tr("该账户已存在", "This account already exists")))
    }
    return form.directive(keeping: original?.src).flatMap { text in
        if let original {
            guard let current = EntryLocator(original).resolve(in: ledger.entries) else {
                return .failure(FolderSaveError(message: tr("原来的账户已经变了，请重新打开编辑", "The account has changed: reopen the editor")))
            }
            let checked = checkText(text, nil)
            guard checked.ok, checked.entries.count == 1, checked.entries.first?.type == .open else {
                return .failure(FolderSaveError(message: checked.msg ?? tr("开户信息无法解析", "The opening details could not be parsed")))
            }
            var op = entryOp(current, text: text)
            op.date = form.date
            let ops: [Op]
            if form.date == current.date {
                ops = [op]
            } else {
                var insert = Op(kind: .insert, path: current.file)
                insert.date = form.date
                insert.text = text
                ops = [entryOp(current, text: nil), insert]
            }
            return folderSave(ops, before: ledger, main: folderMain(folder), folder: folder)
        }
        var draft = Draft()
        draft.kind = .raw
        draft.raw = text
        return prepareFolderSave(draft, folder: folder)
    }
}

/// Closing keeps history; the open directive captured by the editor must still match and there may be only one close.
public func prepareFolderClose(_ original: Entry, date: String, folder: URL) -> Result<FolderSave, FolderSaveError> {
    guard date.count == 10, dateAt(scalars(date), 0) == date, isCalendarDate(date), date >= original.date else {
        return .failure(FolderSaveError(message: tr("关闭日期必须有效且不早于开立日期", "The closing date must be valid and no earlier than the opening date")))
    }
    guard original.type == .open, let account = original.account, let ledger = loadLedger(folder: folder),
          EntryLocator(original, startLine: original.startLine).resolve(in: ledger.entries.filter { $0.file == original.file }) != nil else {
        return .failure(FolderSaveError(message: tr("原来的账户已经变了，请重新打开编辑", "The account has changed: reopen the editor")))
    }
    guard !ledger.entries.contains(where: { $0.type == .close && $0.account == account }) else {
        return .failure(FolderSaveError(message: tr("该账户已关闭", "This account is already closed")))
    }
    var draft = Draft()
    draft.kind = .raw
    draft.raw = "\(date) close \(account)"
    return prepareFolderSave(draft, folder: folder)
}
