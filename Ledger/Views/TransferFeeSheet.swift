import SwiftUI
import LedgerKit

/// Compatibility shortcut: both entrances edit the same isolated currency/rate/fee session.
struct TransferFeeSheet: View {
    @Environment(Store.self) private var store
    var body: some View {
        if let L = store.L, let D = store.D { RateSheet(L: L, D: D, startAtFee: true) }
    }
}

struct FeeFields: View {
    @Environment(Store.self) private var store
    @Binding var draft: Draft
    let L: Ledger
    let D: Derived
    /// opens the fee account picker. The sheet lives on the page holding this section: a sheet attached to a
    /// List section is copied onto every row, so the copies fight over it and it closes as soon as it opens.
    let choosePayer: () -> Void

    private var expense: Bool { draft.kind == .expense }
    private var target: String { conversionCurrency(draft, L, D) ?? draft.currency }
    private var mode: TransferFeeMode { draft.feeMode ?? .added }
    private var payer: String { Self.payer(draft) }

    /// the account the fee comes out of
    static func payer(_ draft: Draft) -> String {
        switch draft.feeMode ?? .added {
        case .separate: return draft.feeFunding ?? draft.funding
        case .deducted: return draft.to
        default: return draft.funding
        }
    }
    private var feeCurrency: String { draft.feeCurrency ?? (expense ? target : draft.currency) }
    private var currencies: [String] {
        Array(Set((D.currencies + (L.accounts[payer]?.currencies ?? []) + [draft.currency, target, feeCurrency]).filter { !$0.isEmpty })).sorted()
    }
    private var modeBinding: Binding<TransferFeeMode> {
        Binding(get: { mode }, set: { value in
            var next = draft
            next.feeMode = value
            if value == .included { next.feeCurrency = draft.currency }
            if value == .deducted { next.feeCurrency = target }
            if value == .separate && next.feeFunding == nil { next.feeFunding = draft.funding }
            if value != .separate { next.feeFunding = nil }
            draft = next
        })
    }

    var body: some View {
        Section {
            Picker(LS("扣费方式"), selection: modeBinding) {
                ForEach(expense ? [.added, .separate] : TransferFeeMode.allCases, id: \.self) { value in
                    Text(expense && value == .added ? LS("由付款账户另付") : value.label).tag(value)
                }
            }
            .accessibilityIdentifier("transfer.fee.mode")
            LabeledContent(LS("金额")) {
                TextField(LS("手续费金额，可不填"), text: Binding(get: { draft.transferFee ?? "" }, set: {
                    var next = draft; next.transferFee = $0.trimmed.isEmpty ? nil : $0
                    if next.feeCurrency == nil { next.feeCurrency = feeCurrency }
                    draft = next
                }))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("transfer.fee.amount")
            }
            Picker(LS("手续费币种"), selection: Binding(get: { feeCurrency }, set: {
                var next = draft; next.feeCurrency = $0; draft = next
            })) {
                ForEach(currencies, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("transfer.fee.currency")
            .disabled(!expense && (mode == .included || mode == .deducted))
            if mode == .separate {
                Button { hideKeyboard(); choosePayer() } label: {
                    LabeledContent { Text(accountTitle(L, payer)).foregroundStyle(.secondary) } label: {
                        Label(LS("扣费账户"), systemImage: "building.columns").labelStyle(ControlLabelStyle())
                    }
                }
                .accessibilityIdentifier("transfer.fee.account")
            } else {
                LabeledContent(LS("手续费由"), value: accountTitle(L, payer))
            }
        } header: {
            Text(LS("手续费（可不填）"))
        } footer: {
            if expense {
                Text(LS("账单金额和换算金额均不含手续费；手续费另计，下方显示合计扣款。账单币种的手续费按本次汇率换算，其他币种请选择单独支付。"))
            } else {
                Text(LS("内扣费用不增加总扣款；另扣费用单独支付。实际到账填写净额，手续费单列 Expenses:Fee:Bank。"))
            }
        }
        .id("rate.fee.section")
        if (evalAmount(draft.transferFee ?? "") ?? 0) > 0 {
            if expense, let b = expenseFeeBreakdown(draft, L, D) {
                Section(LS("金额核对")) {
                    LabeledContent(LS("商品扣款"), value: money(b.purchaseDebit, b.purchaseCurrency))
                    LabeledContent(LS("手续费"), value: money(b.fee, b.feeCurrency))
                    LabeledContent(LS("付款账户合计扣款"), value: money(b.totalDebit, b.purchaseCurrency))
                    if b.payer != draft.funding || b.debitCurrency != b.purchaseCurrency {
                        LabeledContent(LS("另付手续费"), value: money(b.feeDebit, b.debitCurrency))
                    }
                }
                .sensitive()
            } else if !expense, let b = transferBreakdown(draft, target: target) {
                Section(LS("金额核对")) {
                    LabeledContent(LS("转出账户扣款"), value: money(b.sourceDebit, draft.currency))
                    LabeledContent(LS("参与兑换"), value: money(b.principal, draft.currency))
                    LabeledContent(LS("手续费"), value: money(b.fee, b.feeCurrency))
                    if b.netReceived > 0 { LabeledContent(LS("实际到账"), value: money(b.netReceived, target)) }
                    if mode == .separate || b.feeCurrency != draft.currency && mode == .added {
                        LabeledContent(LS("另付手续费"), value: money(b.fee, b.feeCurrency))
                    }
                }
                .sensitive()
            }
        }
    }
}
