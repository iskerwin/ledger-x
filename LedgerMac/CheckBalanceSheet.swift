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
        let usual = folderDerived(ledger, config: nil).acctCcy[account] ?? ledger.accounts[account]?.currencies.first ?? ledger.base
        let held = Set(ledger.final[account]?.keys.map { $0 } ?? []).union(ledger.accounts[account]?.currencies ?? [])
        currencies = held.union([usual]).sorted()
        _currency = State(initialValue: usual)
    }

    var body: some View {
        let book = balance(ledger, account: account, currency: currency, endOf: day)
        let actual = number(amount)
        VStack(spacing: 0) {
            Card(summary: true) { Headline(label: accountTitle(ledger, account) + " · 账面余额", value: money(book, currency)) }
                .fixedSize(horizontal: false, vertical: true)
                .padding([.horizontal, .top], 20)
            // rows of their own height rather than a form in a box of a set height, which cut them off
            VStack(spacing: 0) {
                if currencies.count > 1 {
                    Picker("币种", selection: $currency) {
                        ForEach(currencies, id: \.self) { Text($0).tag($0) }
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
                LabeledContent("实际余额") {
                    TextField("实际余额", text: $amount, prompt: Text("0.00"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(maxWidth: 200)
                }
                .padding(.vertical, 8)
                Divider()
                // always in its place, so the sheet doesn't move while typing
                LabeledContent("差额") {
                    Text(actual.map { signedMoney($0 - book, currency) } ?? " ")
                        .monospacedDigit()
                        .foregroundStyle(actual.map { abs($0 - book) > 0.005 } == true ? Color.loss : Color.secondary)
                }
                .padding(.vertical, 8)
                Divider()
                DateRow(title: "日期", day: $day, latest: Date())
                    .padding(.vertical, 8)
            }
            .padding(.horizontal, 12)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding([.horizontal, .top], 20)
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("写入") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 460)
    }

    private func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
    }

    private func save() {
        guard let value = number(amount) else {
            message = "请输入有效的余额"
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
