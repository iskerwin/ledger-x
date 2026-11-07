import SwiftUI
import LedgerKit

struct CheckBalanceSheet: View {
    let ledger: Ledger
    let account: String
    let folder: URL
    private let currencies: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var day = Day.today()
    @State private var currency: String
    @State private var amount = ""
    @State private var message = ""
    @State private var saving = false

    init(ledger: Ledger, account: String, folder: URL) {
        self.ledger = ledger
        self.account = account
        self.folder = folder
        let usual = Derived(ledger).acctCcy[account] ?? ledger.accounts[account]?.currencies.first ?? ledger.base
        let held = Set(ledger.final[account]?.keys.map { $0 } ?? []).union(ledger.accounts[account]?.currencies ?? [])
        currencies = held.union([usual]).sorted()
        _currency = State(initialValue: usual)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent(chinese ? "账户" : "Account", value: accountTitle(ledger, account))
                DatePicker(chinese ? "日期" : "Date", selection: date, in: ...Date(), displayedComponents: .date)
                Picker(chinese ? "币种" : "Currency", selection: $currency) {
                    ForEach(currencies, id: \.self) { Text($0).tag($0) }
                }
                TextField(chinese ? "实际余额" : "Actual Balance", text: $amount)
            }
            .formStyle(.grouped)
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32)
            HStack {
                Spacer()
                Button(chinese ? "取消" : "Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chinese ? "写入" : "Write") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 460)
    }

    private var date: Binding<Date> {
        Binding(get: { Day.date(day) ?? Date() }, set: { day = Day.string($0) })
    }

    private func save() {
        guard let value = Double(amount.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) else {
            message = chinese ? "请输入有效的余额" : "Enter a valid balance"
            return
        }
        saving = true
        message = ""
        let account = account, day = day, currency = currency, folder = folder
        Task { @MainActor in
            let result = await Task.detached { prepareFolderBalance(account: account, day: day, amount: value, currency: currency, folder: folder) }.value
            saving = false
            do {
                try commitFolderSave(try result.get(), folder: folder)
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
