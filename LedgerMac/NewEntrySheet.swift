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
            Form {
                Picker(selection: $draft.kind) {
                    ForEach([DraftKind.expense, .income, .transfer], id: \.self) { Text($0.label).tag($0) }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .disabled(draft.replacing != nil)
                DatePicker(chinese ? "日期" : "Date", selection: date, displayedComponents: .date)
                TextField(chinese ? "收付款方" : "Payee", text: $draft.payee)
                TextField(chinese ? "备注" : "Note", text: $draft.narration)
                TextField(chinese ? "金额" : "Amount", text: $draft.amount)
                accounts
                // always in its place, so the form doesn't move when it's needed
                TextField(chinese ? "入账金额" : "Amount Received", text: $draft.toAmount)
                    .opacity(needsAmountReceived ? 1 : 0)
                    .disabled(!needsAmountReceived)
            }
            .formStyle(.grouped)
            // every row in sight whichever kind this is: left to itself a form in a sheet takes less than it needs, and scrolls
            .frame(height: 400)
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32)
            HStack {
                Spacer()
                Button(chinese ? "取消" : "Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chinese ? "保存" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 460)
        .onChange(of: draft.kind) {
            draft.account = ""
            message = ""
        }
        .onChange(of: draft.funding) {
            draft.currency = derived.acctCcy[draft.funding] ?? ledger.base
        }
        .alert(review?.issues.first?.title ?? "", isPresented: reviewing) {
            if review?.issues.contains(where: \.blocking) == false {
                Button(chinese ? "仍然保存" : "Save Anyway") { if let review { write(review) } }
            }
            Button(chinese ? "返回修改" : "Go Back", role: .cancel) {}
        } message: {
            Text(review?.issues.map(\.detail).joined(separator: "\n") ?? "")
        }
    }

    @ViewBuilder private var accounts: some View {
        switch draft.kind {
        case .transfer:
            accountPicker(chinese ? "转出账户" : "From", prefixes: ["Assets:", "Liabilities:"], selection: $draft.funding)
            accountPicker(chinese ? "转入账户" : "To", prefixes: ["Assets:", "Liabilities:"], selection: $draft.to)
        case .income:
            accountPicker(chinese ? "收入科目" : "Category", prefixes: ["Income:"], selection: $draft.account)
            accountPicker(chinese ? "收款账户" : "Account", prefixes: ["Assets:", "Liabilities:"], selection: $draft.funding)
        default:
            accountPicker(chinese ? "支出科目" : "Category", prefixes: ["Expenses:"], selection: $draft.account)
            accountPicker(chinese ? "付款账户" : "Account", prefixes: ["Assets:", "Liabilities:"], selection: $draft.funding)
        }
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
        draft.kind == .transfer && (!draft.toAmount.isEmpty || (conversionCurrency(draft, ledger, derived) ?? draft.currency) != draft.currency)
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
