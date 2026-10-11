import SwiftUI
import LedgerKit

struct VerifyDest: Hashable {}

/// current-balance assertions that followed new entries: check them against the bank in one go
struct BalanceVerifyView: View {
    @EnvironmentObject var store: Store
    @State private var bank: [String: String] = [:]
    @FocusState private var focus: String?

    var body: some View {
        List {
            if let L = store.L {
                let today = Day.today()
                let items = store.toVerify.compactMap { v in currentBalanceAssertion(L, v, today: today).map { (v, $0) } }
                if items.isEmpty {
                    Section { Label(LS("余额都已核对"), systemImage: "checkmark.seal").foregroundStyle(Color.gain) }
                }
                ForEach(items, id: \.0.id) { item in
                    row(item.0, item.1)
                }
                if items.count > 1 {
                    Section {
                        Button { store.markVerified(items.map { $0.0 }) } label: { Label(LS("全部与银行一致"), systemImage: "checkmark.circle") }
                    }
                }
                Section { EmptyView() } footer: {
                    Text(LS("记账时，日期在今天之后的余额断言会跟着更新为记账后的余额，并列在这里。打开银行 App 对照：一致就点「与银行一致」；不一致说明有交易记错或漏记，可以先去账户明细里找，或按银行余额写入断言。"))
                }
            }
        }
        .navigationTitle(LS("余额待核对"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func row(_ v: BalanceToVerify, _ r: BalanceResult) -> some View {
        let typed = bank[v.id].flatMap { evalAmount($0.replacingOccurrences(of: ",", with: "")) }
        let diff = typed.map { $0 - r.entry.number }
        Section {
            LabeledContent(LS("账本余额"), value: money(r.entry.number, v.currency)).sensitive()
            LabeledContent(LS("银行余额")) {
                TextField(LS("可不填"), text: Binding(get: { bank[v.id] ?? "" }, set: { bank[v.id] = $0 }))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focus, equals: v.id)
            }
            if let d = diff, abs(d) > 0.005 {
                Text(LS("与账本相差 %@", money(d, v.currency))).font(.caption).foregroundStyle(Color.warn).sensitive()
                NavigationLink(value: AccountDest(name: v.account)) { Text(LS("查看账户明细")) }
                Button(LS("按银行余额写入断言")) {
                    guard let amount = typed else { return }
                    var op = runningBalanceOp(RunningBalance(r), amount: amount)
                    op.silent = nil
                    op.label = LS("余额核对：") + v.account + " " + r.entry.date
                    focus = nil
                    Task { await store.commit([op], word: LS("已写入余额断言")) }
                }
            } else {
                Button { focus = nil; store.markVerified([v]) } label: { Label(LS("与银行一致"), systemImage: "checkmark") }
            }
        } header: {
            Text(acctLabel(v.account) + " · " + r.entry.date).textCase(nil)
        }
    }
}

/// a line on the overview while some current balances wait for a check
struct VerifyBanner: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if let L = store.L {
            let today = Day.today()
            let n = store.toVerify.filter { currentBalanceAssertion(L, $0, today: today) != nil }.count
            if n > 0 {
                Section {
                    NavigationLink(value: VerifyDest()) {
                        Label(LS("%@ 个账户余额待核对", n), systemImage: "checklist").foregroundStyle(Color.warn)
                    }
                }
            }
        }
    }
}
