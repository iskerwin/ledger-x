import SwiftUI
import LedgerKit

struct NewEntrySheet: View {
    let ledger: Ledger
    let folder: URL
    private let derived: Derived
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Draft
    @State private var message = ""
    @State private var saving = false
    @State private var review: FolderSave?
    @State private var editingFee = false
    @FocusState private var payeeFocused: Bool

    init(ledger: Ledger, config: LedgerXConfig?, folder: URL, editing: Draft? = nil) {
        self.ledger = ledger
        self.folder = folder
        let derived = Derived(ledger)
        self.derived = derived
        var draft = editing ?? Draft()
        if editing == nil { draft.currency = ledger.base }
        if editing == nil, let funding = config?.defaultFunding, derived.openAccounts.contains(funding) {
            draft.funding = funding
            draft.currency = derived.acctCcy[funding] ?? ledger.base
        }
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(selection: $draft.kind) {
                ForEach(kinds, id: \.self) { Text($0.label).tag($0) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(draft.replacing != nil)
            .padding([.horizontal, .top], 20)
            Form {
                DatePicker("日期", selection: date, displayedComponents: .date)
                TextField("收付款方", text: $draft.payee)
                    .focused($payeeFocused)
                TextField("备注", text: $draft.narration)
                amountRow("金额", text: $draft.amount, account: draft.kind == .transfer ? draft.funding : "", currency: $draft.currency)
                accounts
                // always in their places, so the form doesn't move when they're needed
                amountRow("入账金额", text: $draft.toAmount, account: draft.to, currency: targetCurrency)
                    .opacity(needsAmountReceived ? 1 : 0)
                    .disabled(!needsAmountReceived)
                LabeledContent("手续费") {
                    Button(feeSummary) { editingFee = true }
                        .popover(isPresented: $editingFee) { feeForm }
                }
                .opacity(draft.kind == .transfer ? 1 : 0)
                .disabled(draft.kind != .transfer)
            }
            .formStyle(.grouped)
            // every row in sight whichever kind this is: left to itself a form in a sheet takes less than it needs, and scrolls
            .frame(height: 350)
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 460)
        .onAppear { payeeFocused = true }
        .onChange(of: draft.kind) {
            draft.account = ""
            message = ""
            // nothing kept that this kind's form no longer shows
            if draft.kind != .transfer {
                draft.transferFee = nil
                draft.feeCurrency = nil
                draft.feeMode = nil
                draft.feeFunding = nil
                draft.targetCurrency = nil
                draft.toAmount = ""
            }
        }
        .onChange(of: draft.funding) {
            let held = ledger.accounts[draft.funding]?.currencies ?? []
            draft.currency = derived.acctCcy[draft.funding] ?? (held.isEmpty || held.contains(ledger.base) ? ledger.base : held[0])
        }
        .onChange(of: draft.to) { draft.targetCurrency = nil }
        .onChange(of: draft.currency) { keepFeeCurrency() }
        .onChange(of: targetCurrency.wrappedValue) { keepFeeCurrency() }
        .alert(review?.issues.first?.title ?? "", isPresented: reviewing) {
            if review?.issues.contains(where: \.blocking) == false {
                Button("仍然保存") { if let review { write(review) } }
            }
            Button("返回修改", role: .cancel) {}
        } message: {
            Text(review?.issues.map(\.detail).joined(separator: "\n") ?? "")
        }
    }

    @ViewBuilder private var accounts: some View {
        switch draft.kind {
        case .transfer:
            accountPicker("转出账户", prefixes: ["Assets:", "Liabilities:"], selection: $draft.funding)
            accountPicker("转入账户", prefixes: ["Assets:", "Liabilities:"], selection: $draft.to)
        case .refund:
            accountPicker("支出科目", prefixes: ["Expenses:"], selection: $draft.account)
            accountPicker("退回账户", prefixes: ["Assets:", "Liabilities:"], selection: $draft.funding)
        case .income:
            accountPicker("收入科目", prefixes: ["Income:"], selection: $draft.account)
            accountPicker("收款账户", prefixes: ["Assets:", "Liabilities:"], selection: $draft.funding)
        default:
            accountPicker("支出科目", prefixes: ["Expenses:"], selection: $draft.account)
            accountPicker("付款账户", prefixes: ["Assets:", "Liabilities:"], selection: $draft.funding)
        }
    }

    /// the amount with its currency, to choose only where the account holds more than one
    private func amountRow(_ title: String, text: Binding<String>, account: String, currency: Binding<String>) -> some View {
        let held = ledger.accounts[account]?.currencies ?? []
        return LabeledContent(title) {
            HStack {
                TextField(title, text: text)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                if held.count > 1 {
                    Picker(title, selection: currency) {
                        ForEach(held, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            // as tall with its menu as without, so the rows below stay put when an account brings one
            .frame(minHeight: 24)
        }
    }

    private var targetCurrency: Binding<String> {
        Binding(get: { conversionCurrency(draft, ledger, derived) ?? draft.currency }, set: { draft.targetCurrency = $0 })
    }

    private var feeMode: TransferFeeMode { draft.feeMode ?? .added }

    private var feeSummary: String {
        guard let fee = evalAmount(draft.transferFee ?? ""), fee > 0 else { return "无" }
        return money(fee, draft.feeCurrency ?? draft.currency)
    }

    private var feeForm: some View {
        Form {
            TextField("金额", text: Binding(get: { draft.transferFee ?? "" }, set: {
                draft.transferFee = $0.isEmpty ? nil : $0
                if draft.feeCurrency == nil { draft.feeCurrency = draft.currency }
            }))
            Picker("币种", selection: Binding(get: { draft.feeCurrency ?? draft.currency }, set: { draft.feeCurrency = $0 })) {
                ForEach(feeCurrencies, id: \.self) { Text($0).tag($0) }
            }
            // what it's taken out of decides
            .disabled(feeMode == .included || feeMode == .deducted)
            Picker("扣费方式", selection: Binding(get: { feeMode }, set: { setFeeMode($0) })) {
                ForEach(TransferFeeMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            accountPicker("扣费账户", prefixes: ["Assets:", "Liabilities:"], selection: Binding(get: { draft.feeFunding ?? "" }, set: { draft.feeFunding = $0 }))
                .opacity(feeMode == .separate ? 1 : 0)
                .disabled(feeMode != .separate)
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 230)
    }

    private var feeCurrencies: [String] {
        let payer = feeMode == .separate ? draft.feeFunding ?? "" : feeMode == .deducted ? draft.to : draft.funding
        let held = ledger.accounts[payer]?.currencies ?? []
        return Array(Set(derived.currencies + held + [draft.currency, targetCurrency.wrappedValue, draft.feeCurrency ?? ""]).subtracting([""])).sorted()
    }

    private func setFeeMode(_ mode: TransferFeeMode) {
        draft.feeMode = mode
        draft.feeFunding = mode == .separate ? draft.feeFunding ?? draft.funding : nil
        keepFeeCurrency()
    }

    /// a fee taken out of an amount is in that amount's currency
    private func keepFeeCurrency() {
        guard draft.transferFee != nil else { return }
        switch feeMode {
        case .included: draft.feeCurrency = draft.currency
        case .deducted: draft.feeCurrency = targetCurrency.wrappedValue
        case .added, .separate: break
        }
    }

    /// a refund is only ever edited here: it is written from the purchase, on the phone
    private var kinds: [DraftKind] {
        draft.kind == .refund ? [.refund] : [.expense, .income, .transfer]
    }

    private func accountPicker(_ title: String, prefixes: [String], selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("").tag("")
            ForEach(derived.rankAccounts(prefixes), id: \.self) { Text(acctDisplay($0)).tag($0) }
        }
    }

    private var date: Binding<Date> {
        Binding(get: { Day.date(draft.date) ?? Date() }, set: { draft.date = Day.string($0) })
    }

    private var reviewing: Binding<Bool> {
        Binding(get: { review != nil }, set: { if !$0 { review = nil } })
    }

    private var needsAmountReceived: Bool {
        draft.kind == .transfer && (!draft.toAmount.isEmpty || targetCurrency.wrappedValue != draft.currency
            || (ledger.accounts[draft.to]?.currencies.count ?? 0) > 1)
    }

    private func save() {
        saving = true
        message = ""
        let draft = draft, folder = folder
        Task { @MainActor in
            let result = await Task.detached { prepareFolderSave(draft, folder: folder) }.value
            saving = false
            switch result {
            case .failure(let error): message = error.message
            case .success(let prepared):
                if prepared.issues.isEmpty { write(prepared) } else { review = prepared }
            }
        }
    }

    private func write(_ prepared: FolderSave) {
        do {
            try commitFolderSave(prepared, folder: folder)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
