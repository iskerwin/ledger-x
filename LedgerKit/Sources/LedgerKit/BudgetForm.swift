import Foundation

/// The budget editor's fields. Zero switches a budget off; a change dated later preserves its history.
public struct BudgetForm: Equatable {
    public var account = ""
    public var period = BudgetPeriod.monthly
    public var amount = ""
    public var currency: String
    public var date: String

    public init(currency: String, date: String = Day.ym(Day.today()) + "-01") {
        self.currency = currency
        self.date = date
    }

    public init(_ budget: Budget, date: String = Day.ym(Day.today()) + "-01") {
        self.init(currency: budget.currency, date: date)
        account = budget.account
        period = budget.period
        amount = jsNumberString(budget.amount)
    }

    public func directive(keeping original: String? = nil) -> Result<String, FolderSaveError> {
        guard date.count == 10, dateAt(scalars(date), 0) == date, isCalendarDate(date) else {
            return .failure(FolderSaveError(message: tr("请输入有效的生效日期", "Enter a valid effective date")))
        }
        guard isAccountName(account), account.hasPrefix("Expenses:") || account.hasPrefix("Income:") else {
            return .failure(FolderSaveError(message: tr("请选择支出或收入科目", "Choose an expense or income account")))
        }
        guard let value = evalAmount(amount), value.isFinite, value >= 0 else {
            return .failure(FolderSaveError(message: tr("预算金额必须是有效的非负数", "The budget amount must be a valid nonnegative number")))
        }
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty, currencyLength(scalars(code), 0) == scalars(code).count else {
            return .failure(FolderSaveError(message: tr("请输入有效的币种代码", "Enter a valid currency code")))
        }
        var lines = [budgetLine(date, account, period, value, code)]
        let oldLines = (original ?? "").components(separatedBy: "\n")
        let header = scalars(oldLines.first ?? "")
        let comment = str(header.dropFirst(stripComment(header).count))
        if !comment.isEmpty { lines[0] += " " + comment }
        // Metadata and comments on an edited directive are not fields in this form, so keep them verbatim.
        lines += oldLines.dropFirst()
        return .success(lines.joined(separator: "\n"))
    }
}

/// The UI supplies the exact same-day entry it saw (if any), rather than replacing whichever entry a later read finds.
/// `previous` is the older budget being adjusted: it must still match before a new dated record can be added.
public func prepareFolderBudget(_ form: BudgetForm, replacing original: Entry? = nil, previous: Entry? = nil,
                                folder: URL) -> Result<FolderSave, FolderSaveError> {
    guard let ledger = loadLedger(folder: folder) else {
        return .failure(FolderSaveError(message: tr("这个文件夹里没有账本", "No ledger in this folder")))
    }
    let all = budgets(ledger)
    let changed = FolderSaveError(message: tr("预算记录已经变了，请重新打开编辑", "The budget record has changed: reopen the editor"))
    for expected in [original, previous].compactMap({ $0 }) {
        guard let current = EntryLocator(expected).resolve(in: ledger.entries),
              all.contains(where: { $0.entry === current && $0.account == form.account }) else { return .failure(changed) }
    }
    let onDay = all.filter { $0.account == form.account && $0.date == form.date }
    guard onDay.count <= 1 else {
        return .failure(FolderSaveError(message: tr("该科目同一天有多条预算，请先在历史记录中处理", "This account has several budgets on the same day: resolve them in History first")))
    }
    guard onDay.isEmpty || original != nil else {
        return .failure(FolderSaveError(message: tr("该科目这一天已有预算，请重新打开编辑", "This account already has a budget on that day: reopen the editor")))
    }
    if let previous, original == nil, all.contains(where: { $0.account == form.account && $0.date > previous.date && $0.date <= form.date }) {
        return .failure(changed)
    }
    // Editing a date must not displace another dated record, even if the original itself still matches.
    if let original, let existing = onDay.first?.entry,
       EntryLocator(original).resolve(in: [existing]) == nil { return .failure(changed) }
    return form.directive(keeping: original?.src).flatMap { text in
        var draft = original.map(folderSourceDraft) ?? Draft()
        draft.kind = .raw
        draft.raw = text
        return prepareFolderSave(draft, folder: folder)
    }
}
