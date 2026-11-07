import SwiftUI
import LedgerKit

/// a small choice, as the phone's chips
struct EntryChip: View {
    let title: String
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .foregroundStyle(selected ? Color.jade : Color.primary)
                .background(selected ? Color.jade.soft : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// chips that scroll sideways
struct ChipRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content }
        }
    }
}

/// an account's kind on its colour, as the phone's account list
struct AccountMark: View {
    let account: String
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: accountSymbol(account))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Color.jade)
            .frame(width: size, height: size)
            .background(Color.jade.soft, in: Circle())
            .accessibilityHidden(true)
    }
}

func accountSymbol(_ account: String) -> String {
    let parts = account.components(separatedBy: ":")
    switch parts.count > 1 ? parts[1] : account {
    case "Bank": return "building.columns.fill"
    case "EWallet": return "wallet.pass.fill"
    case "Cash": return "banknote.fill"
    case "Brokerage": return "chart.line.uptrend.xyaxis"
    case "Crypto": return "bitcoinsign"
    case "Receivable": return "tray.and.arrow.down.fill"
    case "CreditCard": return "creditcard.fill"
    case "Loan": return "percent"
    default: return "folder.fill"
    }
}

/// "支付宝 ¥50 + 招行 ¥40 · 优惠 ¥10": who pays what
func payingSummary(_ draft: Draft, _ ledger: Ledger) -> String? {
    guard hasCombo(draft) else { return nil }
    var parts: [String] = []
    if let rest = comboRest(draft), rest > 0.004, !draft.funding.isEmpty { parts.append(accountTitle(ledger, draft.funding) + " " + money(rest, draft.currency)) }
    for extra in draft.extraFunds where !extra.account.isEmpty {
        parts.append(accountTitle(ledger, extra.account) + " " + (evalAmount(extra.amount).map { money($0, draft.currency) } ?? "?"))
    }
    var summary = parts.joined(separator: " + ")
    if discountAllowed(draft), let discount = evalAmount(draft.discount), discount > 0 {
        summary += (summary.isEmpty ? "" : " · ") + "优惠 " + money(discount, draft.currency)
    }
    return summary
}

/// an account from a menu, the most used first; one no longer open still shows
struct AccountField: View {
    let title: String
    let prefixes: [String]
    let derived: Derived
    @Binding var account: String

    var body: some View {
        let ranked = derived.rankAccounts(prefixes)
        Picker(title, selection: $account) {
            Text("").tag("")
            if !account.isEmpty && !ranked.contains(account) { Text(acctDisplay(account)).tag(account) }
            ForEach(ranked, id: \.self) { Text(acctDisplay($0)).tag($0) }
        }
    }
}

/// every account of a kind, searchable
struct AccountChooser: View {
    let accounts: [String]
    let ledger: Ledger
    let current: String
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var shown: [String] {
        let typed = query.trimmed
        guard !typed.isEmpty else { return accounts }
        return accounts.filter { [$0, accountTitle(ledger, $0), acctDisplay($0)].contains { $0.localizedCaseInsensitiveContains(typed) } }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("搜索", text: $query).textFieldStyle(.roundedBorder)
            List(shown, id: \.self) { account in
                Button {
                    pick(account)
                    dismiss()
                } label: {
                    HStack {
                        Text(acctDisplay(account)).lineLimit(1)
                        Spacer()
                        if account == current { Image(systemName: "checkmark").foregroundStyle(Color.jade) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .padding(12)
        .frame(width: 300, height: 360)
    }
}

/// a panel's title and 完成
private struct PanelFrame<Content: View>: View {
    let title: String
    var height: CGFloat = 480
    let done: () -> Void
    var cancel: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(.top, 16)
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                if let cancel {
                    Button("取消", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                }
                Button("完成", action: done).keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 460, height: height)
        .background(Color.page)
    }
}

// MARK: - 币种、汇率与手续费

/// The currency of the amount, and when the account is in another one, what it comes to there: 账单金额 × 汇率 = 换算金额, the two
/// filled in last give the third. Works on its own copy: nothing changes until 完成, which checks it as the phone's sheet does.
struct RateSheet: View {
    @Binding var draft: Draft
    let ledger: Ledger
    let derived: Derived
    @Environment(\.dismiss) private var dismiss
    @State private var working = Draft()
    @State private var currency = ""
    @State private var target = ""
    @State private var reverse = false
    @State private var error: String?
    @State private var quotes: [Bool: String] = [:]
    @State private var explicitQuote = false
    @State private var amount = ""
    @State private var rate = ""
    @State private var converted = ""
    /// the two filled in last, newest first; the third is worked out
    @State private var recent: [RatePart] = [.amount, .rate]
    @State private var loaded = false
    @FocusState private var focus: RatePart?

    private var transfer: Bool { working.kind == .transfer }
    private var hasFee: Bool { working.kind == .expense || transfer }
    private var candidate: Draft {
        var next = working
        next.currency = currency
        next.targetCurrency = target
        next.amount = amount
        if transfer {
            next.toAmount = converted
        } else {
            next.byRate = computed == .converted
            next.rate = rate.trimmed
            next.paid = converted
        }
        return next
    }
    private var other: String? { target.isEmpty ? nil : target }
    private var currencies: [String] {
        Array(Set(derived.currencies + ledger.accounts.values.flatMap(\.currencies) + [working.currency, target]).subtracting([""])).sorted()
    }
    private func perUnit(_ value: Double) -> Double { reverse && value > 0 ? 1 / value : value }
    private var computed: RatePart { RatePart.allCases.first { !recent.contains($0) } ?? .converted }
    private var ledgerRate: Double? {
        guard let other, other != currency else { return nil }
        return convertAmount(ledger, 1, from: currency, to: other, date: working.date)
    }

    var body: some View {
        PanelFrame(title: hasFee ? "币种、汇率与手续费" : "币种与汇率", height: 560, done: save, cancel: { dismiss() }) {
            Section {
                Picker("账单币种", selection: $currency) {
                    ForEach(currencies, id: \.self) { Text($0).tag($0) }
                }
                Picker("目标币种", selection: $target) {
                    ForEach(currencies, id: \.self) { Text($0).tag($0) }
                }
            }
            if let error { Text(error).foregroundStyle(Color.loss) }
            if let other, other != currency {
                if !transfer && hasCombo(working) {
                    Text("组合付款时，各账户要与支出同币种。").foregroundStyle(.secondary)
                } else {
                    conversion(other)
                }
            } else {
                Section { row("金额", $amount, unit: currency, part: .amount) }
            }
            if hasFee { feeSections }
        }
        .onAppear(perform: load)
        .onChange(of: currency) { old, _ in currencyChanged(old) }
        .onChange(of: target) { old, _ in currencyChanged(old) }
        .onChange(of: amount) { edited(.amount) }
        .onChange(of: rate) { edited(.rate) }
        .onChange(of: converted) { edited(.converted) }
    }

    /// another currency: start again from the ledger's rate
    private func currencyChanged(_ old: String) {
        guard loaded, !old.isEmpty else { return }
        if working.feeMode == .included { working.feeCurrency = currency }
        if working.feeMode == .deducted { working.feeCurrency = target }
        quotes = [:]
        explicitQuote = false
        recent = [.amount, .rate]
        rate = ledgerRate.map { rateString(perUnit($0)) } ?? ""
        recompute()
    }

    @ViewBuilder private func conversion(_ other: String) -> some View {
        Section {
            row(transfer ? "转出金额" : "账单金额", $amount, unit: currency, part: .amount)
            LabeledContent("1 \(reverse ? other : currency) =") {
                HStack {
                    TextField("汇率", text: $rate, prompt: Text(ledgerRate.map(rateString) ?? ""))
                        .labelsHidden()
                        .focused($focus, equals: .rate)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .foregroundStyle(computed == .rate ? Color.secondary : Color.primary)
                    Text(reverse ? currency : other).foregroundStyle(.secondary)
                }
            }
            row(transfer ? "实际到账" : "换算金额", $converted, unit: other, part: .converted)
            if transfer, let sent = evalAmount(amount), let quoted = Double(rate), let received = evalAmount(converted),
               let expected = solveTransferRate(.converted, draft: candidate, amount: sent, rate: perUnit(quoted), received: received), abs(expected - received) > 0.011 {
                Text("银行报价与实际金额存在差异，请核对；已填金额不会被自动覆盖。").foregroundStyle(Color.warn)
            }
        }
        Section {
            if transfer {
                Button("交换汇率方向", systemImage: "arrow.left.arrow.right") {
                    quotes[reverse] = rate
                    reverse.toggle()
                    if let saved = quotes[reverse] {
                        rate = saved
                    } else if let quoted = Double(rate), quoted > 0 {
                        rate = rateString(1 / quoted)
                    }
                }
            }
            Button("重置汇率", systemImage: "arrow.counterclockwise") {
                explicitQuote = false
                recent = [.rate] + recent.filter { $0 != .rate }.prefix(1)
                rate = ledgerRate.map { rateString(perUnit($0)) } ?? ""
                recompute()
            }
            .disabled(ledgerRate == nil)
        }
    }

    private func row(_ title: String, _ text: Binding<String>, unit: String, part: RatePart) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: text, prompt: Text("0.00"))
                    .labelsHidden()
                    .focused($focus, equals: part)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .foregroundStyle(computed == part ? Color.secondary : Color.primary)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 手续费

    private var feeMode: TransferFeeMode { working.feeMode ?? .added }
    private var feePayer: String {
        switch feeMode {
        case .separate: return working.feeFunding ?? working.funding
        case .deducted: return working.to
        default: return working.funding
        }
    }
    private var feeCurrency: String { working.feeCurrency ?? (working.kind == .expense ? (other ?? currency) : currency) }

    @ViewBuilder private var feeSections: some View {
        let expense = working.kind == .expense
        let feeCurrencies = Array(Set(derived.currencies + (ledger.accounts[feePayer]?.currencies ?? []) + [currency, target, feeCurrency]).subtracting([""])).sorted()
        Section("手续费") {
            Picker("扣费方式", selection: Binding(get: { feeMode }, set: setFeeMode)) {
                ForEach(expense ? [TransferFeeMode.added, .separate] : TransferFeeMode.allCases, id: \.self) { mode in
                    Text(expense && mode == .added ? "由付款账户另付" : mode.label).tag(mode)
                }
            }
            LabeledContent("金额") {
                TextField("金额", text: Binding(get: { working.transferFee ?? "" }, set: { value in
                    working.transferFee = value.trimmed.isEmpty ? nil : value
                    if working.feeCurrency == nil { working.feeCurrency = feeCurrency }
                    error = nil
                    recompute()
                }), prompt: Text("0.00"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
            }
            Picker("手续费币种", selection: Binding(get: { feeCurrency }, set: { working.feeCurrency = $0 })) {
                ForEach(feeCurrencies, id: \.self) { Text($0).tag($0) }
            }
            .disabled(!expense && (feeMode == .included || feeMode == .deducted))
            if feeMode == .separate {
                AccountField(title: "扣费账户", prefixes: ["Assets:", "Liabilities:"], derived: derived, account: Binding(get: { feePayer }, set: { working.feeFunding = $0 }))
            } else {
                LabeledContent("手续费由", value: accountTitle(ledger, feePayer))
            }
        }
        if (evalAmount(working.transferFee ?? "") ?? 0) > 0 {
            if expense, let breakdown = expenseFeeBreakdown(candidate, ledger, derived) {
                Section("金额核对") {
                    LabeledContent("商品扣款", value: money(breakdown.purchaseDebit, breakdown.purchaseCurrency))
                    LabeledContent("手续费", value: money(breakdown.fee, breakdown.feeCurrency))
                    LabeledContent("付款账户合计扣款", value: money(breakdown.totalDebit, breakdown.purchaseCurrency))
                    if breakdown.payer != working.funding || breakdown.debitCurrency != breakdown.purchaseCurrency {
                        LabeledContent("另付手续费", value: money(breakdown.feeDebit, breakdown.debitCurrency))
                    }
                }
            } else if !expense, let breakdown = transferBreakdown(candidate, target: target) {
                Section("金额核对") {
                    LabeledContent("转出账户扣款", value: money(breakdown.sourceDebit, currency))
                    LabeledContent("参与兑换", value: money(breakdown.principal, currency))
                    LabeledContent("手续费", value: money(breakdown.fee, breakdown.feeCurrency))
                    if breakdown.netReceived > 0 { LabeledContent("实际到账", value: money(breakdown.netReceived, target)) }
                }
            }
        }
    }

    private func setFeeMode(_ mode: TransferFeeMode) {
        working.feeMode = mode
        if mode == .included { working.feeCurrency = currency }
        if mode == .deducted { working.feeCurrency = target }
        if mode == .separate && working.feeFunding == nil { working.feeFunding = working.funding }
        if mode != .separate { working.feeFunding = nil }
        error = nil
        recompute()
    }

    // MARK: working it out

    private func load() {
        guard !loaded else { return }
        working = draft
        currency = draft.currency
        target = conversionCurrency(draft, ledger, derived) ?? draft.currency
        reverse = draft.kind == .transfer && draft.fxRate?.base == target && target != currency
        amount = evalAmount(draft.amount).map { isExpression(draft.amount) ? toFixed($0, 2) : draft.amount } ?? ""
        let given = draft.kind == .transfer ? draft.toAmount : draft.paid
        if draft.kind != .transfer && draft.byRate && !draft.rate.trimmed.isEmpty {
            rate = draft.rate.trimmed
            recent = [.rate, .amount]
        } else if evalAmount(given) != nil {
            converted = given
            recent = [.converted, .amount]
        } else {
            rate = ledgerRate.map { rateString(perUnit($0)) } ?? ""
            recent = [.rate, .amount]
        }
        if draft.kind == .transfer, let kept = draft.fxRate, quoteCurrenciesMatch(kept.text, currency, target),
           let sent = evalAmount(amount), let received = evalAmount(given),
           abs(kept.amount - sent) < 0.005, abs(kept.toAmount - received) < 0.005 {
            let parts = kept.text.split(separator: " ")
            if parts.count == 5 {
                rate = String(parts[3])
                explicitQuote = true
            }
        } else {
            recompute()
        }
        // the onChange of what load set must not count as typing
        DispatchQueue.main.async { loaded = true }
    }

    /// typed into `part`: it and the one typed before it give the third
    private func edited(_ part: RatePart) {
        // only what is typed: the worked-out part changes too, but not under the cursor
        guard loaded, focus == part else { return }
        if part == .rate { explicitQuote = true }
        quotes = [:]
        if recent.first != part { recent = [part] + recent.filter { $0 != part }.prefix(1) }
        recompute()
    }

    private func recompute() {
        if transfer, computed == .rate, explicitQuote { return }
        let value = transfer
            ? solveTransferRate(computed, draft: candidate, amount: evalAmount(amount), rate: Double(rate.trimmed).map(perUnit), received: evalAmount(converted))
            : solveRate(computed, amount: evalAmount(amount), rate: Double(rate.trimmed).map(perUnit), converted: evalAmount(converted))
        let shown = value.map { computed == .rate ? rateString(perUnit($0)) : toFixed($0, 2) } ?? ""
        switch computed {
        case .amount: if amount != shown { amount = shown }
        case .rate: if rate != shown { rate = shown }
        case .converted: if converted != shown { converted = shown }
        }
    }

    private func save() {
        var next = candidate
        next.currency = currency
        let inferred = accountCurrency(transfer ? next.to : next.funding, ledger, derived)
        next.targetCurrency = target == inferred && draft.targetCurrency == nil ? nil : target
        if let issue = conversionCurrencyIssue(next, ledger, derived) { error = issue.message; return }
        if transfer, let issue = transferFeeIssue(next, ledger, derived) { error = issue.message; return }
        if next.kind == .expense, let issue = expenseFeeIssue(next, ledger, derived) { error = issue.message; return }
        if !transfer, hasCombo(next), target != currency {
            error = "组合付款时，各账户要与支出同币种。"
            return
        }
        if let other, other != currency, transfer || !hasCombo(next) {
            guard let sent = evalAmount(amount), sent > 0, let received = evalAmount(converted), received > 0,
                  let quoted = Double(rate.trimmed), quoted.isFinite, quoted > 0 else {
                error = "请输入有效金额和汇率"
                return
            }
            setConversion(&next, amount: amount.trimmed, rate: transfer ? rateString(perUnit(quoted)) : rate.trimmed, converted: converted.trimmed, computed: computed)
            if transfer {
                next.fxRate = KeptRate(text: "1 \(reverse ? other : currency) = \(rate.trimmed) \(reverse ? currency : other)", amount: sent, toAmount: received)
            }
        } else {
            next.amount = amount.trimmed
            // the same currency: nothing to convert
            next.byRate = false
            next.rate = ""
            next.paid = ""
            if transfer { next.toAmount = "" }
        }
        draft = next
        dismiss()
    }
}

// MARK: - 组合付款与优惠

/// other accounts paying set parts, a discount recorded as income; the main paying account pays what is left
struct PaySheet: View {
    @Binding var draft: Draft
    let ledger: Ledger
    let derived: Derived
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rest = comboRest(draft)
        PanelFrame(title: "组合付款与优惠", done: { dismiss() }) {
            Section {
                LabeledContent("总额", value: evalAmount(draft.amount).map { money($0, draft.currency) } ?? "—")
                LabeledContent(draft.funding.isEmpty ? "主账户" : accountTitle(ledger, draft.funding),
                               value: rest.map { "付余下的 " + money(max(0, $0), draft.currency) } ?? "付余下的部分")
            }
            Section("其他付款账户") {
                ForEach($draft.extraFunds) { $extra in
                    HStack {
                        AccountField(title: "账户", prefixes: ["Assets:", "Liabilities:"], derived: derived, account: $extra.account)
                            .labelsHidden()
                        TextField("金额", text: $extra.amount, prompt: Text("0.00"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(maxWidth: 100)
                        Button("删除", systemImage: "minus.circle") {
                            let id = extra.id
                            draft.extraFunds.removeAll { $0.id == id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Button("添加付款账户", systemImage: "plus.circle") { draft.extraFunds.append(ExtraFund(account: "")) }
            }
            if discountAllowed(draft) {
                Section("优惠") {
                    LabeledContent("优惠金额") {
                        TextField("优惠金额", text: $draft.discount, prompt: Text("0.00"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                    AccountField(title: "记到", prefixes: ["Income:"], derived: derived, account: $draft.discountAccount)
                }
            }
            if let issue = comboIssue(draft, ledger, derived) {
                Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warn)
            }
        }
    }
}

// MARK: - 标签

/// the entry's tags, its events and 待确认 in one place
struct MarkSheet: View {
    @Binding var draft: Draft
    let ledger: Ledger
    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""
    @State private var badTag = false

    var body: some View {
        let events = draft.kind == .transfer ? [] : ledgerEvents(ledger, today: draft.date).filter { ($0.entry != nil && $0.covers(draft.date)) || draft.events.contains($0.tag) }
        let eventTags = Set(events.map(\.tag))
        let hidden: Set<String> = ["transfer", "fx", "reimbursed", "refund", "reimbursement"]
        let known = Array(Set(ledger.txns.suffix(2000).flatMap(\.tags))).filter { !hidden.contains($0) && !draft.tags.contains($0) && !eventTags.contains($0) }.sorted()
        PanelFrame(title: "标记", done: finish) {
            if !events.isEmpty {
                Section("事件") {
                    ForEach(events) { event in
                        Toggle(event.title, isOn: Binding(get: { draft.events.contains(event.tag) }, set: { on in
                            if on { draft.events.append(event.tag) } else { draft.events.removeAll { $0 == event.tag } }
                            draft.eventsTouched = true
                        }))
                    }
                }
            }
            Section("标签") {
                ForEach(draft.tags, id: \.self) { tag in
                    HStack {
                        Text("#" + tag)
                        Spacer()
                        Button("删除标签 #\(tag)", systemImage: "xmark.circle.fill") { draft.tags.removeAll { $0 == tag } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("新标签", text: $newTag).onSubmit(addTyped)
                    Button("添加", action: addTyped).disabled(newTag.trimmed.isEmpty)
                }
                if badTag {
                    Text("标签只能用英文字母、数字和 - _ / .（Beancount 的规定）").foregroundStyle(Color.warn)
                }
                if !known.isEmpty {
                    ChipRow {
                        ForEach(known.prefix(12), id: \.self) { tag in
                            EntryChip(title: "#" + tag, selected: false) { add(tag) }
                        }
                    }
                }
            }
            Section {
                Toggle("待确认（!）", isOn: Binding(get: { draft.flag == "!" }, set: { draft.flag = $0 ? "!" : "*" }))
            }
        }
    }

    private func finish() {
        if !newTag.trimmed.isEmpty {
            addTyped()
            if badTag { return }
        }
        dismiss()
    }

    private func addTyped() {
        add(newTag)
        if !badTag { newTag = "" }
    }

    private func add(_ typed: String) {
        let tag = typed.trimmed.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: " ", with: "-")
        // Beancount takes only these in a tag
        badTag = !tag.isEmpty && tag.range(of: #"^[A-Za-z0-9\-_/.]+$"#, options: .regularExpression) == nil
        guard !tag.isEmpty, !badTag, !draft.tags.contains(tag) else { return }
        draft.tags.append(tag)
    }
}
