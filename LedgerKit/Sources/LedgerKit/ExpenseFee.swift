import Foundation

/// Expense amounts describe the purchase only. A bank fee is paid in addition, or by a separate
/// account; the sheet shows the total debit explicitly rather than changing the purchase quote.
public struct ExpenseFeeBreakdown {
    public let purchaseDebit: Double
    public let purchaseCurrency: String
    public let fee: Double
    public let feeCurrency: String
    public let feeDebit: Double
    public let debitCurrency: String
    public let payer: String
    public let totalDebit: Double
}

public func expenseFeeBreakdown(_ d: Draft, _ L: Ledger, _ D: Derived) -> ExpenseFeeBreakdown? {
    guard d.kind == .expense, let amount = evalAmount(d.amount), amount.isFinite, amount > 0 else { return nil }
    let target = conversionCurrency(d, L, D) ?? d.currency
    let purchase: Double
    if target == d.currency { purchase = roundMoney(amount, 2) }
    else if d.byRate, let rate = draftRate(d), rate.isFinite, rate > 0 { purchase = mulMoney(amount, rate, 2) }
    else if let paid = evalAmount(d.paid), paid.isFinite, paid > 0 { purchase = paid }
    else { return nil }
    let text = (d.transferFee ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let fee = text.isEmpty ? 0 : evalAmount(text), fee.isFinite, fee >= 0 else { return nil }
    let feeCurrency = d.feeCurrency ?? target
    let separate = d.feeMode == .separate
    let payer = separate ? (d.feeFunding ?? "") : d.funding
    let debitCurrency = separate ? feeCurrency : target
    let feeDebit: Double
    if feeCurrency == debitCurrency { feeDebit = roundMoney(fee, 2) }
    else if feeCurrency == d.currency, let rate = draftRate(d), rate.isFinite, rate > 0 {
        feeDebit = mulMoney(fee, rate, 2)
    } else { return nil }
    let total = roundMoney(purchase + (payer == d.funding && debitCurrency == target ? feeDebit : 0), 2)
    return ExpenseFeeBreakdown(purchaseDebit: purchase, purchaseCurrency: target, fee: fee,
                               feeCurrency: feeCurrency, feeDebit: feeDebit, debitCurrency: debitCurrency,
                               payer: payer, totalDebit: total)
}

public func expenseFeeIssue(_ d: Draft, _ L: Ledger, _ D: Derived) -> DraftIssue? {
    let text = (d.transferFee ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    guard let fee = evalAmount(text), fee.isFinite, fee >= 0 else {
        return DraftIssue(.fee, tr("手续费须为零或正数", "The fee must be zero or positive"))
    }
    guard fee > 0 else { return nil }
    guard d.kind == .expense, !hasCombo(d), !d.split, !d.reimb else {
        return DraftIssue(.fee, tr("复杂支出的手续费请在分录中填写", "Enter fees for complex expenses in the postings editor"))
    }
    guard d.feeMode == nil || d.feeMode == .added || d.feeMode == .separate else {
        return DraftIssue(.fee, tr("支出手续费请选择另付或其他账户支付", "For an expense fee, choose an additional or separate payment"))
    }
    guard L.accounts[transferFeeAccount] != nil else {
        return DraftIssue(.fee, tr("请先开立手续费科目 Expenses:Fee:Bank", "Open Expenses:Fee:Bank before recording a fee"))
    }
    let target = conversionCurrency(d, L, D) ?? d.currency
    let currency = d.feeCurrency ?? target
    let separate = d.feeMode == .separate
    let payer = separate ? (d.feeFunding ?? "") : d.funding
    guard let account = L.accounts[payer], payer.hasPrefix("Assets:") || payer.hasPrefix("Liabilities:") else {
        return DraftIssue(.fee, tr("请选择手续费扣费账户", "Choose the account that pays the fee"))
    }
    if !separate && currency != d.currency && currency != target {
        return DraftIssue(.fee, tr("第三种币种的手续费请选择单独支付", "Pay a fee in a third currency separately"))
    }
    let charged = separate ? currency : target
    if !account.currencies.isEmpty && !account.currencies.contains(charged) {
        return DraftIssue(.fee, tr("扣费账户不支持手续费币种 \(charged)", "The fee-paying account cannot hold \(charged)"))
    }
    if let category = L.accounts[transferFeeAccount], !category.currencies.isEmpty && !category.currencies.contains(currency) {
        return DraftIssue(.fee, tr("手续费科目不支持所选币种", "The fee account does not support the selected currency"))
    }
    return nil
}

func appendExpenseFee(_ tx: inout TxDraft, draft d: Draft, _ L: Ledger, _ D: Derived) -> Bool {
    guard expenseFeeIssue(d, L, D) == nil else { return false }
    guard (evalAmount(d.transferFee ?? "") ?? 0) > 0 else { return true }
    guard let b = expenseFeeBreakdown(d, L, D) else { return false }
    var posting = TxPosting(account: transferFeeAccount, amount: b.fee, currency: b.feeCurrency)
    if b.feeCurrency != b.debitCurrency {
        if let rate = draftRate(d) {
            let quote = d.byRate ? d.rate.trimmingCharacters(in: .whitespaces) : moneyText(rate, 5)
            if mulMoney(b.fee, Double(quote) ?? 0, 2) == b.feeDebit {
                posting.suffix = "@ \(quote) \(b.debitCurrency)"
            } else { posting.priceTotal = b.feeDebit; posting.priceCcy = b.debitCurrency }
        } else { return false }
    }
    tx.postings.insert(posting, at: 0)
    if let i = tx.postings.firstIndex(where: { $0.account == b.payer && $0.currency == b.debitCurrency && (Double($0.units ?? "") ?? 0) < 0 }) {
        tx.postings[i].units = numText(roundMoney((Double(tx.postings[i].units ?? "") ?? 0) - b.feeDebit, 2))
    } else { tx.postings.append(TxPosting(account: b.payer, amount: -b.feeDebit, currency: b.debitCurrency)) }
    if let mode = d.feeMode { tx.meta.append(("fee_mode", mode.rawValue)) }
    if d.feeMode == .separate { tx.meta.append(("fee_account", b.payer)) }
    return true
}

/// Only offer the simple expense form when every posting and metadata item round-trips exactly.
public func expenseFeeDraft(_ t: Entry, _ L: Ledger, _ D: Derived) -> Draft? {
    guard t.type == .txn, !isTransferTag(t) else { return nil }
    let fees = t.postings.filter { $0.account == transferFeeAccount }
    let purchases = t.postings.filter { $0.account.hasPrefix("Expenses:") && $0.account != transferFeeAccount }
    guard fees.count == 1, purchases.count == 1, let fee = fees.first, let purchase = purchases.first,
          let amount = purchase.units, amount > 0, let currency = purchase.currency,
          let feeAmount = fee.units, feeAmount > 0, let feeCurrency = fee.currency,
          let purchaseWeight = weight(purchase), purchaseWeight.n > 0 else { return nil }
    let declared = t.meta["fee_mode"]?.stringValue
    guard declared == nil || declared == "added" || declared == "separate" else { return nil }
    let mode = declared.flatMap(TransferFeeMode.init(rawValue:))
    let separate = t.meta["fee_account"]?.stringValue
    let paid = t.postings.filter { ($0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:")) && ($0.units ?? 0) < 0 }
    guard t.postings.count == purchases.count + fees.count + paid.count, !paid.isEmpty,
          let funding = paid.first(where: { $0.currency == purchaseWeight.c && !(mode == .separate && $0.account == separate) })
            ?? paid.first(where: { $0.currency == purchaseWeight.c }) else { return nil }
    var d = newDraft(.expense, D, defaultFunding: funding.account)
    d.date = t.date; d.flag = t.flag; d.payee = t.payee; d.narration = t.narration
    d.account = purchase.account; d.funding = funding.account
    d.amount = jsNumberString(amount); d.currency = currency; d.targetCurrency = purchaseWeight.c
    if currency != purchaseWeight.c {
        d.paid = jsNumberString(purchaseWeight.n)
        if let price = purchase.price, !price.total, let rate = price.number {
            d.byRate = true; d.rate = jsNumberString(rate)
        }
    }
    d.transferFee = jsNumberString(feeAmount); d.feeCurrency = feeCurrency
    d.feeMode = mode; d.feeFunding = mode == .separate ? separate : nil
    d.tags = t.tags; d.keepLinks = t.links
    d.keepMeta = t.meta.items.filter { !["filename", "lineno", "fee_mode", "fee_account"].contains($0.0) }
        .map { KeptMeta(key: $0.0, value: $0.1.stringValue.map(quoted) ?? $0.1.display) }
    let checked = validateText(draftText(d, L, D), L, single: true)
    guard checked.ok, let regenerated = checked.txn, sameTxn(t, regenerated) else { return nil }
    return d
}
