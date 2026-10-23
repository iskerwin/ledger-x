import SwiftUI
import LedgerKit

/// 记一笔: the currency of the amount, and when the account is in another one, what it comes to there.
/// 账单金额 × 汇率 = 换算金额 — the two filled in last give the third. The rate starts from the ledger's.
struct RateSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let L: Ledger
    let D: Derived
    var startAtFee = false
    @State private var working = Draft()
    @State private var ownerLedgerID = ""

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
    @State private var choosingFeePayer = false
    @FocusState private var focus: RatePart?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var inputLayout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppSpacing.icon))
            : AnyLayout(HStackLayout(spacing: AppSpacing.icon))
    }

    private var d: Draft { working }
    private var candidate: Draft {
        var next = working
        next.currency = currency; next.targetCurrency = target
        next.amount = amount
        if next.kind == .transfer { next.toAmount = converted }
        else {
            next.byRate = computed == .converted
            next.rate = next.kind == .transfer ? rateString(Double(rate.trimmed).map(perUnit) ?? 0) : rate.trimmed
            next.paid = converted
        }
        return next
    }
    private var feeBinding: Binding<Draft> {
        Binding(get: { candidate }, set: { value in
            working.transferFee = value.transferFee
            working.feeCurrency = value.feeCurrency
            working.feeMode = value.feeMode
            working.feeFunding = value.feeFunding
            error = nil
            recompute()
        })
    }
    /// the currency of the account charged (received into, for a transfer)
    private var other: String? { target.isEmpty ? nil : target }
    private var currencies: [String] {
        var values = D.currencies
        values += L.accounts.values.flatMap { $0.currencies }
        values.append(d.currency)
        if !target.isEmpty { values.append(target) }
        return Array(Set(values)).sorted()
    }
    private func perUnit(_ r: Double) -> Double { reverse && r > 0 ? 1 / r : r }
    private func displayed(_ r: Double) -> Double { reverse && r > 0 ? 1 / r : r }
    private var computed: RatePart { RatePart.allCases.first { !recent.contains($0) } ?? .converted }
    private var ledgerRate: Double? {
        guard let fc = other, fc != currency else { return nil }
        return convertAmount(L, 1, from: currency, to: fc, date: d.date)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    Picker(LS("账单币种"), selection: $currency) {
                        ForEach(currencies, id: \.self) { c in Text(c).tag(c) }
                    }
                    .onChange(of: currency) { old, _ in
                        guard loaded, !old.isEmpty else { return }
                        if working.feeMode == .included { working.feeCurrency = currency }
                        if working.feeMode == .deducted { working.feeCurrency = target }
                        quotes = [:]
                        explicitQuote = false
                        // another currency: start again from the ledger's rate
                        recent = [.amount, .rate]
                        rate = ledgerRate.map { rateString(displayed($0)) } ?? ""
                        recompute()
                    }
                    Picker(LS("目标币种"), selection: $target) {
                        ForEach(currencies, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("rate.targetCurrency")
                    .onChange(of: target) { old, _ in
                        guard loaded, !old.isEmpty else { return }
                        if working.feeMode == .included { working.feeCurrency = currency }
                        if working.feeMode == .deducted { working.feeCurrency = target }
                        quotes = [:]
                        explicitQuote = false
                        recent = [.amount, .rate]
                        rate = ledgerRate.map { rateString(displayed($0)) } ?? ""
                        recompute()
                    }
                }
                if let error = error { Text(error).foregroundStyle(Color.loss).id("rate.error") }
                if let fc = other, fc != currency {
                    if d.kind != .transfer && hasCombo(d) {
                        Section {
                            Text(LS("组合付款时，各账户要与支出同币种。")).foregroundStyle(.secondary)
                        }
                    } else {
                        conversion(fc)
                    }
                } else {
                    Section {
                        row(LS("金额"), $amount, unit: currency, part: .amount)
                    } footer: {
                        if let fc = other { Text(LS("与%@同为 %@，不用换算。", accountTitle(L, d.kind == .transfer ? d.to : d.funding), fc)) }
                    }
                }
                if d.kind == .expense || d.kind == .transfer {
                    FeeFields(draft: feeBinding, L: L, D: D) { choosingFeePayer = true }
                }
            }
            .navigationTitle(d.kind == .expense || d.kind == .transfer ? LS("币种、汇率与手续费") : LS("币种与汇率"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { focus = nil; hideKeyboard(); dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) { Button { save() } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }.fontWeight(.semibold) }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    HideKeyboardButton { focus = nil }
                }
            }
            // on the Form, not inside the fee section: there it would be copied onto every row
            .sheet(isPresented: $choosingFeePayer) {
                AccountPicker(title: LS("扣费账户"), prefixes: ["Assets:", "Liabilities:"], current: FeeFields.payer(candidate)) { value in
                    var next = feeBinding.wrappedValue; next.feeFunding = value; feeBinding.wrappedValue = next
                }
            }
            .onAppear(perform: load)
            .onChange(of: amount) { _, _ in edited(.amount) }
            .onChange(of: rate) { _, _ in edited(.rate) }
            .onChange(of: converted) { _, _ in edited(.converted) }
            .onChange(of: loaded) { _, ready in
                if ready && startAtFee { proxy.scrollTo("rate.fee.section", anchor: .top) }
            }
            .onChange(of: store.cfg.id) { _, _ in dismiss() }
            .onChange(of: error) { _, message in
                if message != nil { proxy.scrollTo("rate.error", anchor: .top) }
            }
            }
        }
        .formSheet()
    }

    @ViewBuilder
    private func conversion(_ fc: String) -> some View {
        Section {
            row(d.kind == .transfer ? LS("转出金额") : LS("账单金额"), $amount, unit: currency, part: .amount)
            inputLayout {
                Text("1 \(reverse ? fc : currency) =").foregroundStyle(.secondary)
                HStack(spacing: AppSpacing.icon) {
                TextField(ledgerRate.map(rateString) ?? "1.17912", text: $rate)
                    .accessibilityIdentifier("rate.rate")
                    .keyboardType(.decimalPad)
                    .focused($focus, equals: .rate)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(computed == .rate ? Color.secondary : Color.primary)
                    .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 120)
                Text(reverse ? currency : fc).foregroundStyle(.secondary)
                }
            }
            row(d.kind == .transfer ? LS("实际到账") : LS("换算金额"), $converted, unit: fc, part: .converted)
        } footer: {
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                if let a = evalAmount(amount), let r = Double(rate), let c = evalAmount(converted) {
                    if d.kind == .transfer {
                        let expected = solveTransferRate(.converted, draft: candidate, amount: a, rate: perUnit(r), received: c)
                        Text(LS("转出金额与实际到账按所选扣费方式计算。")).font(.caption)
                        if let expected = expected, abs(expected - c) > 0.011 {
                            Text(LS("银行报价与实际金额存在差异，请核对；已填金额不会被自动覆盖。")).foregroundStyle(Color.warn)
                        }
                    } else {
                        Text("\(toFixed(a, 2)) \(currency) × \(rateString(perUnit(r))) ≈ \(toFixed(c, 2)) \(fc)").monospacedDigit()
                    }
                }
                Text(LS("填任意两项，%@由另外两项算出。", partName(computed)))
            }
        }
        Section {
            if d.kind == .transfer {
                    Button {
                        focus = nil; hideKeyboard()
                        quotes[reverse] = rate
                        reverse.toggle()
                        if let saved = quotes[reverse] { rate = saved }
                        else if let r = Double(rate), r > 0 { rate = rateString(1 / r) }
                    } label: { Label(LS("交换汇率方向"), systemImage: "arrow.left.arrow.right").labelStyle(ControlLabelStyle()) }
                    .accessibilityLabel(LS("交换汇率方向"))
            }
            Button {
                explicitQuote = false
                recent = [.rate] + recent.filter { $0 != .rate }.prefix(1)
                rate = ledgerRate.map { rateString(displayed($0)) } ?? ""
                recompute()
            } label: { Label(LS("重置汇率"), systemImage: "arrow.counterclockwise").labelStyle(ControlLabelStyle()) }
            .disabled(ledgerRate == nil)
        } footer: {
            if let r = ledgerRate {
                Text(LS("账本里 %@ 的汇率：1 %@ = %@ %@", d.date, currency, rateString(r), fc))
            } else {
                Text(LS("账本里还没有 %@ 和 %@ 之间的汇率。", currency, fc))
            }
        }
    }

    private func row(_ title: String, _ text: Binding<String>, unit: String, part: RatePart) -> some View {
        inputLayout {
            Text(title)
            HStack(spacing: AppSpacing.icon) {
            TextField("0.00", text: text)
                .accessibilityIdentifier(part == .amount ? "rate.amount" : "rate.converted")
                .keyboardType(.decimalPad)
                .focused($focus, equals: part)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(computed == part ? Color.secondary : Color.primary)
            Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private func partName(_ p: RatePart) -> String {
        switch p {
        case .amount: return d.kind == .transfer ? LS("转出金额") : LS("账单金额")
        case .rate: return LS("汇率")
        case .converted: return d.kind == .transfer ? LS("实际到账") : LS("换算金额")
        }
    }

    private func load() {
        guard !loaded else { return }
        working = store.draft
        ownerLedgerID = store.cfg.id
        currency = d.currency
        target = conversionCurrency(d, L, D) ?? d.currency
        reverse = d.kind == .transfer && d.fxRate?.base == target && target != currency
        amount = evalAmount(d.amount).map { isExpression(d.amount) ? toFixed($0, 2) : d.amount } ?? ""
        let given = d.kind == .transfer ? d.toAmount : d.paid
        if d.kind != .transfer && d.byRate && !d.rate.trimmed.isEmpty {
            rate = d.rate.trimmed
            recent = [.rate, .amount]
        } else if evalAmount(given) != nil {
            converted = given
            recent = [.converted, .amount]
        } else {
            rate = ledgerRate.map { rateString(displayed($0)) } ?? ""
            recent = [.rate, .amount]
        }
        if d.kind == .transfer, let kept = d.fxRate, quoteCurrenciesMatch(kept.text, currency, target),
           let a = evalAmount(amount), let received = evalAmount(given),
           abs(kept.amount - a) < 0.005, abs(kept.toAmount - received) < 0.005 {
            let parts = kept.text.split(separator: " ")
            if parts.count == 5 { rate = String(parts[3]); explicitQuote = true }
        } else { recompute() }
        // the onChange of what load set must not count as typing
        DispatchQueue.main.async { loaded = true }
    }

    /// typed into `p`: it and the one typed before it give the third
    private func edited(_ p: RatePart) {
        // only what is typed: the worked-out part changes too, but not under the cursor
        guard loaded, focus == p else { return }
        if p == .rate { explicitQuote = true }
        quotes = [:]
        if recent.first != p { recent = [p] + recent.filter { $0 != p }.prefix(1) }
        recompute()
    }

    private func recompute() {
        if d.kind == .transfer, computed == .rate, explicitQuote { return }
        let v = d.kind == .transfer
            ? solveTransferRate(computed, draft: candidate, amount: evalAmount(amount), rate: Double(rate.trimmed).map(perUnit), received: evalAmount(converted))
            : solveRate(computed, amount: evalAmount(amount), rate: Double(rate.trimmed).map(perUnit), converted: evalAmount(converted))
        let s = v.map { computed == .rate ? rateString(displayed($0)) : toFixed($0, 2) } ?? ""
        switch computed {
        case .amount: if amount != s { amount = s }
        case .rate: if rate != s { rate = s }
        case .converted: if converted != s { converted = s }
        }
    }

    private func save() {
        guard store.cfg.id == ownerLedgerID else { dismiss(); return }
        var x = candidate
        x.currency = currency
        let inferred = accountCurrency(x.kind == .transfer ? x.to : x.funding, L, D)
        x.targetCurrency = target == inferred && d.targetCurrency == nil ? nil : target
        if let issue = conversionCurrencyIssue(x, L, D) { error = issue.message; return }
        if x.kind == .transfer, let issue = transferFeeIssue(x, L, D) { error = issue.message; return }
        if x.kind == .expense, let issue = expenseFeeIssue(x, L, D) { error = issue.message; return }
        if x.kind != .transfer, hasCombo(x), target != currency {
            error = LS("组合付款时，各账户要与支出同币种。"); return
        }
        if let fc = other, fc != currency, x.kind == .transfer || !hasCombo(x) {
            guard let a = evalAmount(amount), a > 0, let c = evalAmount(converted), c > 0,
                  let r = Double(rate.trimmed), r.isFinite, r > 0 else {
                error = LS("请输入有效金额和汇率"); return
            }
            setConversion(&x, amount: amount.trimmed, rate: x.kind == .transfer ? rateString(perUnit(r)) : rate.trimmed, converted: converted.trimmed, computed: computed)
            if x.kind == .transfer {
                x.fxRate = KeptRate(text: "1 \(reverse ? fc : currency) = \(rate.trimmed) \(reverse ? currency : fc)", amount: a, toAmount: c)
            }
        } else {
            x.amount = amount.trimmed
            // the same currency: nothing to convert
            x.byRate = false; x.rate = ""; x.paid = ""
            if x.kind == .transfer { x.toAmount = "" }
            x.edited = nil
        }
        store.draft = x
        focus = nil; hideKeyboard(); dismiss()
    }
}

