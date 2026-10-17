import SwiftUI
import LedgerKit

struct PettyCashSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var company = ""
    @State private var amount = ""
    @State private var date = Day.today()
    @State private var currency = "CNY"
    @State private var account = ""
    @State private var note = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L, let D = store.D { form(L, D) } else { ProgressView() }
            }
            .keyboardDone()
            .navigationTitle(LS("领取备用金"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() }.disabled(saving) }
            }
            .interactiveDismissDisabled(saving)
            .onChange(of: store.cfg.id) { _, _ in dismiss() }
            .onChange(of: account) { _, value in
                if let allowed = store.L?.accounts[value]?.currencies, !allowed.isEmpty, !allowed.contains(currency) {
                    currency = allowed[0]
                }
            }
            .onAppear {
                currency = store.defaultCurrency ?? store.L?.base ?? "CNY"
                let past = store.L?.txns.last { $0.links.contains(where: isFloatLink) && $0.postings.contains { $0.account == store.receivable && ($0.units ?? 0) < 0 } }
                company = past?.payee ?? ""
                account = past?.postings.first { $0.account.hasPrefix("Assets:") && $0.account != store.receivable && ($0.units ?? 0) > 0 }?.account ?? ""
                if store.defaultCurrency == nil, let own = store.L?.accounts[account]?.currencies.first { currency = own }
            }
        }
    }

    private func form(_ L: Ledger, _ D: Derived) -> some View {
        let link = newLink("float", payee: company.trimmed, date: date, taken: Set(D.allLinks))
        let text = pettyCashText(date: date, company: company, amount: evalAmount(amount) ?? 0, currency: currency,
                                 account: account, receivable: D.receivable, link: link, note: note)
        let full = (L.accounts[D.receivable] == nil || L.accounts[D.receivable]?.implicit == true) && !text.isEmpty ? "\(date) open \(D.receivable)\n\n" + text : text
        let validation = full.isEmpty ? nil : validateText(full, L, single: false)
        return Form {
            Section {
                TextField(LS("公司 / 发放方"), text: $company)
                DateField(value: $date)
                TextField(LS("金额"), text: $amount).keyboardType(.decimalPad)
                Picker(LS("币种"), selection: $currency) {
                    ForEach(Array(Set(D.currencies + [currency])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                AccountField(label: LS("收款账户"), prefixes: ["Assets:"],
                             chips: Array(D.rankAccounts(["Assets:"]).filter { !$0.hasPrefix("Assets:Receivable") }.prefix(6)), value: $account)
                TextField(LS("备注（可选）"), text: $note)
            } footer: {
                Text(LS("领取时增加收款账户余额，同时记为负的报销应收；垫付时选择这笔备用金即可冲抵。"))
            }
            if !full.isEmpty {
                Section(LS("将写入")) {
                    MonoText(text: full)
                    if validation?.ok == false, let message = validation?.msg { Text(message).foregroundStyle(Color.loss) }
                }
            }
        }
        .disabled(saving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    guard !saving, let ops = store.makeOps(full, extra: OpExtra(label: LS("领取备用金")), single: false) else { return }
                    saving = true
                    Task {
                        let ok = await store.commit(ops)
                        saving = false
                        if ok { dismiss() }
                    }
                } label: {
                    if saving { ProgressView() } else { Text(LS("保存")) }
                }
                .disabled(full.isEmpty || validation?.ok != true || saving)
            }
        }
    }
}
