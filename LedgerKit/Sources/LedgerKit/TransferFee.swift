import Foundation

public let transferFeeAccount = "Expenses:Fee:Bank"

public enum TransferFeeMode: String, Codable, CaseIterable {
    case added, included, deducted, separate
    public var label: String {
        switch self {
        case .added: return tr("转出金额外另扣", "Charged in addition")
        case .included: return tr("转出金额已含手续费", "Included in amount sent")
        case .deducted: return tr("从兑换所得中扣除", "Deducted from proceeds")
        case .separate: return tr("其他账户或币种单独支付", "Paid separately")
        }
    }
}

public struct TransferBreakdown {
    public let principal: Double
    public let sourceDebit: Double
    public let grossReceived: Double
    public let netReceived: Double
    public let fee: Double
    public let feeCurrency: String
    public let feePayer: String
}

/// amount is the entered source amount; toAmount is always the net receipt.
/// A missing mode means an additional fee; do not silently change that interpretation.
public func transferBreakdown(_ d: Draft, target: String) -> TransferBreakdown? {
    guard let amount = evalAmount(d.amount), amount.isFinite, amount > 0 else { return nil }
    let feeText = (d.transferFee ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let fee = feeText.isEmpty ? 0 : evalAmount(feeText), fee.isFinite, fee >= 0 else { return nil }
    let mode = d.feeMode ?? .added
    let feeCcy = d.feeCurrency ?? d.currency
    let principal = roundMoney(amount - (mode == .included ? fee : 0), 2)
    guard principal > 0 else { return nil }
    let net = target == d.currency ? roundMoney(principal - (mode == .deducted ? fee : 0), 2) : (evalAmount(d.toAmount) ?? 0)
    let gross = roundMoney(net + (mode == .deducted ? fee : 0), 2)
    let payer = mode == .deducted ? d.to : mode == .separate ? (d.feeFunding ?? "") : d.funding
    let sourceDebit = roundMoney(principal + (payer == d.funding && feeCcy == d.currency ? fee : 0), 2)
    return TransferBreakdown(principal: principal, sourceDebit: sourceDebit, grossReceived: gross,
                             netReceived: net, fee: fee, feeCurrency: feeCcy, feePayer: payer)
}

/// Convert between the two amounts shown in the sheet, with the fee applied once.
public func solveTransferRate(_ part: RatePart, draft: Draft, amount: Double?, rate: Double?, received: Double?) -> Double? {
    let fee = evalAmount(draft.transferFee ?? "") ?? 0
    let mode = draft.feeMode ?? .added
    let sourceFee = mode == .included ? fee : 0
    let targetFee = mode == .deducted ? fee : 0
    switch part {
    case .converted:
        guard let a = amount, a > sourceFee, let r = rate, r > 0 else { return nil }
        let net = roundMoney(mulMoney(a - sourceFee, r, 2) - targetFee, 2)
        return net > 0 ? net : nil
    case .amount:
        guard let c = received, c > 0, let r = rate, r > 0,
              let converted = divMoney(c + targetFee, r, 2) else { return nil }
        return roundMoney(converted + sourceFee, 2)
    case .rate:
        guard let a = amount, a > sourceFee, let c = received, c > 0 else { return nil }
        return (c + targetFee) / (a - sourceFee)
    }
}

public func quoteCurrenciesMatch(_ text: String, _ source: String, _ target: String) -> Bool {
    let parts = text.split(separator: " ").map(String.init)
    return parts.count == 5 && Set([parts[1], parts[4]]) == Set([source, target])
}

public func conversionCurrency(_ d: Draft, _ L: Ledger, _ D: Derived) -> String? {
    if let c = d.targetCurrency, !c.isEmpty { return c }
    return accountCurrency(d.kind == .transfer ? d.to : d.funding, L, D)
}

public func conversionCurrencyIssue(_ d: Draft, _ L: Ledger, _ D: Derived) -> DraftIssue? {
    guard let c = d.targetCurrency else { return nil }
    let account = d.kind == .transfer ? d.to : d.funding
    guard !account.isEmpty else { return nil }
    if !accountTakes(account, c, L), !(L.accounts[account]?.currencies.isEmpty ?? true) {
        return DraftIssue(d.kind == .transfer ? .toAmount : .paid,
                          tr("所选账户不支持 \(c)，请选择账户支持的币种", "The selected account does not support \(c)"))
    }
    return nil
}

public func transferFeeIssue(_ d: Draft, _ L: Ledger, _ D: Derived) -> DraftIssue? {
    let text = (d.transferFee ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    guard let fee = evalAmount(text), fee.isFinite, fee >= 0 else {
        return DraftIssue(.fee, tr("手续费须为零或正数", "The fee must be zero or positive"))
    }
    guard fee > 0 else { return nil }
    guard L.accounts[transferFeeAccount] != nil else {
        return DraftIssue(.fee, tr("请先开立手续费科目 Expenses:Fee:Bank", "Open Expenses:Fee:Bank before recording a fee"))
    }
    let currency = d.feeCurrency ?? d.currency
    let mode = d.feeMode ?? .added
    let target = conversionCurrency(d, L, D) ?? d.currency
    if mode == .included && currency != d.currency || mode == .deducted && currency != target {
        return DraftIssue(.fee, tr("内扣手续费须使用被扣金额的币种", "A deducted fee must use the currency it is deducted from"))
    }
    if mode == .included, let amount = evalAmount(d.amount), fee >= amount {
        return DraftIssue(.fee, tr("手续费必须小于转出金额", "The fee must be less than the amount sent"))
    }
    if mode == .deducted, target == d.currency, let amount = evalAmount(d.amount), fee >= amount {
        return DraftIssue(.fee, tr("手续费必须小于转出金额", "The fee must be less than the amount sent"))
    }
    let payer = mode == .deducted ? d.to : mode == .separate ? (d.feeFunding ?? "") : d.funding
    if mode == .separate && (payer.isEmpty || L.accounts[payer] == nil || !(payer.hasPrefix("Assets:") || payer.hasPrefix("Liabilities:"))) {
        return DraftIssue(.fee, tr("请选择手续费扣费账户", "Choose the account that pays the fee"))
    }
    if let account = L.accounts[payer], !account.currencies.isEmpty && !account.currencies.contains(currency) {
        return DraftIssue(.fee, tr("扣费账户不支持手续费币种 \(currency)", "The fee-paying account cannot hold \(currency)"))
    }
    if let account = L.accounts[transferFeeAccount], !account.currencies.isEmpty && !account.currencies.contains(currency) {
        return DraftIssue(.fee, tr("手续费科目不支持所选币种", "The fee account does not support the selected currency"))
    }
    return nil
}

/// Read transfers with an optional fee separately from the amount received. The editor's existing
/// round-trip gate checks all other metadata and rejects transactions this representation cannot hold.
public func transferDraft(_ t: Entry, _ L: Ledger, _ D: Derived) -> Draft? {
    let cardRepayment = t.postings.contains { $0.account.hasPrefix("Liabilities:CreditCard") && ($0.units ?? 0) > 0 }
    guard isTransferTag(t) || cardRepayment,
          t.postings.allSatisfy({ $0.account == transferFeeAccount || $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }) else { return nil }
    let fees = t.postings.filter { $0.account == transferFeeAccount }
    guard fees.count <= 1, fees.allSatisfy({ ($0.units ?? 0) > 0 }) else { return nil }
    let received = t.postings.filter { $0.account != transferFeeAccount && ($0.units ?? 0) > 0 }
    guard received.count == 1, let to = received.first, let tc = to.currency else { return nil }
    let paid = t.postings.filter { $0.account != transferFeeAccount && ($0.units ?? 0) < 0 }
    let declaredMode = t.meta["fee_mode"]?.stringValue
    guard declaredMode == nil || TransferFeeMode(rawValue: declaredMode!) != nil else { return nil }
    let mode = declaredMode.flatMap(TransferFeeMode.init(rawValue:))
    let separatePayer = t.meta["fee_account"]?.stringValue
    let sourceCurrency = to.price?.currency ?? tc
    let candidates = paid.filter { $0.currency == sourceCurrency }
    let from = candidates.first {
        !(mode == .deducted && sourceCurrency == tc && $0.account == to.account)
            && !(mode == .separate && $0.account == separatePayer)
    } ?? candidates.first
    guard let from = from, let fc = from.currency, let out = from.units else { return nil }
    guard paid.count <= (fees.isEmpty ? 1 : 2) else { return nil }
    let fee = fees.first?.units ?? 0
    let feeCcy = fees.first?.currency ?? fc
    let payer = mode == .deducted ? to.account : mode == .separate ? (separatePayer ?? "") : from.account
    guard paid.allSatisfy({ $0.account == from.account || $0.account == payer }) else { return nil }
    let principal = abs(out) - (feeCcy == fc && payer == from.account ? fee : 0)
    guard principal > 0 else { return nil }
    var d = newDraft(.transfer, D, defaultFunding: from.account)
    d.date = t.date; d.funding = from.account; d.to = to.account
    d.currency = fc; d.targetCurrency = tc
    d.amount = jsNumberString(roundMoney(mode == .included ? abs(out) : principal, 2))
    let net = roundMoney((to.units ?? 0) - (mode == .deducted ? fee : 0), 2)
    guard net > 0 else { return nil }
    d.toAmount = fc == tc ? "" : jsNumberString(net)
    d.feeMode = mode; d.feeFunding = mode == .separate ? separatePayer : nil
    d.payee = t.payee; d.narration = t.narration; d.flag = t.flag
    d.tags = t.tags; d.keepLinks = t.links
    if fee > 0 { d.transferFee = jsNumberString(fee); d.feeCurrency = feeCcy }
    if let rate = t.meta["exchange_rate"], fc != tc {
        d.fxRate = KeptRate(text: rate.stringValue ?? rate.display, amount: evalAmount(d.amount) ?? 0, toAmount: net)
    }
    d.keepMeta = t.meta.items.filter { !["filename", "lineno", "fee_mode", "fee_account"].contains($0.0) && !(fc != tc && $0.0 == "exchange_rate") }
        .map { KeptMeta(key: $0.0, value: $0.1.stringValue.map(quoted) ?? $0.1.display) }
    let back = validateText(draftText(d, L, D), L, single: true)
    guard back.ok, let regenerated = back.txn, sameTxn(t, regenerated) else { return nil }
    return d
}
