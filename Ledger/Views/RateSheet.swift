import SwiftUI
import LedgerKit

/// 记一笔: the currency of the amount, and when the account is in another one, what it comes to there.
/// 账单金额 × 汇率 = 换算金额 — the two filled in last give the third. The rate starts from the ledger's.
struct RateSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let L: Ledger
    let D: Derived

    @State private var currency = ""
    @State private var amount = ""
    @State private var rate = ""
    @State private var converted = ""
    /// the two filled in last, newest first; the third is worked out
    @State private var recent: [RatePart] = [.amount, .rate]
    @State private var loaded = false
    @FocusState private var focus: RatePart?

    private var d: Draft { store.draft }
    /// the currency of the account charged (received into, for a transfer)
    private var other: String? {
        d.kind == .transfer ? (d.to.isEmpty ? nil : accountCurrency(d.to, L, D)) : accountCurrency(d.funding, L, D)
    }
    private var computed: RatePart { RatePart.allCases.first { !recent.contains($0) } ?? .converted }
    private var ledgerRate: Double? {
        guard let fc = other, fc != currency else { return nil }
        return convertAmount(L, 1, from: currency, to: fc, date: d.date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(LS("账单币种"), selection: $currency) {
                        ForEach(D.currencies, id: \.self) { c in Text(c).tag(c) }
                    }
                    .onChange(of: currency) { _, _ in
                        guard loaded else { return }
                        // another currency: start again from the ledger's rate
                        recent = [.amount, .rate]
                        rate = ledgerRate.map(rateString) ?? ""
                        recompute()
                    }
                }
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
            }
            .navigationTitle(LS("币种与汇率"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(LS("完成")) { save() }.fontWeight(.semibold) }
            }
            .onAppear(perform: load)
            .onChange(of: amount) { _, _ in edited(.amount) }
            .onChange(of: rate) { _, _ in edited(.rate) }
            .onChange(of: converted) { _, _ in edited(.converted) }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func conversion(_ fc: String) -> some View {
        Section {
            row(d.kind == .transfer ? LS("转出金额") : LS("账单金额"), $amount, unit: currency, part: .amount)
            HStack(spacing: 6) {
                Text(LS("汇率"))
                Spacer(minLength: 8)
                Text("1 \(currency) =").foregroundStyle(.secondary)
                TextField(ledgerRate.map(rateString) ?? "1.17912", text: $rate)
                    .keyboardType(.decimalPad)
                    .focused($focus, equals: .rate)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(computed == .rate ? Color.secondary : Color.primary)
                    .frame(maxWidth: 120)
                Text(fc).foregroundStyle(.secondary)
            }
            row(d.kind == .transfer ? LS("入账金额") : LS("换算金额"), $converted, unit: fc, part: .converted)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let a = evalAmount(amount), let r = Double(rate), let c = evalAmount(converted) {
                    Text("\(toFixed(a, 2)) \(currency) × \(rateString(r)) ≈ \(toFixed(c, 2)) \(fc)").monospacedDigit()
                }
                Text(LS("填任意两项，%@由另外两项算出。", partName(computed)))
            }
        }
        Section {
            Button {
                recent = [.rate] + recent.filter { $0 != .rate }.prefix(1)
                rate = ledgerRate.map(rateString) ?? ""
                recompute()
            } label: { Label(LS("重置汇率"), systemImage: "arrow.counterclockwise") }
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
        HStack(spacing: 6) {
            Text(title)
            Spacer(minLength: 8)
            TextField("0.00", text: text)
                .keyboardType(.decimalPad)
                .focused($focus, equals: part)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(computed == part ? Color.secondary : Color.primary)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func partName(_ p: RatePart) -> String {
        switch p {
        case .amount: return d.kind == .transfer ? LS("转出金额") : LS("账单金额")
        case .rate: return LS("汇率")
        case .converted: return d.kind == .transfer ? LS("入账金额") : LS("换算金额")
        }
    }

    private func load() {
        guard !loaded else { return }
        currency = d.currency
        amount = evalAmount(d.amount).map { isExpression(d.amount) ? toFixed($0, 2) : d.amount } ?? ""
        let given = d.kind == .transfer ? d.toAmount : d.paid
        if d.kind != .transfer && d.byRate && !d.rate.trimmed.isEmpty {
            rate = d.rate.trimmed
            recent = [.rate, .amount]
        } else if evalAmount(given) != nil {
            converted = given
            recent = [.converted, .amount]
        } else {
            rate = ledgerRate.map(rateString) ?? ""
            recent = [.rate, .amount]
        }
        recompute()
        // the onChange of what load set must not count as typing
        DispatchQueue.main.async { loaded = true }
    }

    /// typed into `p`: it and the one typed before it give the third
    private func edited(_ p: RatePart) {
        // only what is typed: the worked-out part changes too, but not under the cursor
        guard loaded, focus == p else { return }
        if recent.first != p { recent = [p] + recent.filter { $0 != p }.prefix(1) }
        recompute()
    }

    private func recompute() {
        let v = solveRate(computed, amount: evalAmount(amount), rate: Double(rate.trimmed), converted: evalAmount(converted))
        let s = v.map { computed == .rate ? rateString($0) : toFixed($0, 2) } ?? ""
        switch computed {
        case .amount: if amount != s { amount = s }
        case .rate: if rate != s { rate = s }
        case .converted: if converted != s { converted = s }
        }
    }

    private func save() {
        var x = store.draft
        x.currency = currency
        if let fc = other, fc != currency, x.kind == .transfer || !hasCombo(x) {
            setConversion(&x, amount: amount.trimmed, rate: rate.trimmed, converted: converted.trimmed, computed: computed)
        } else {
            x.amount = amount.trimmed
            // the same currency: nothing to convert
            x.byRate = false; x.rate = ""; x.paid = ""
            if x.kind == .transfer { x.toAmount = "" }
            x.edited = nil
        }
        store.draft = x
        dismiss()
    }
}
