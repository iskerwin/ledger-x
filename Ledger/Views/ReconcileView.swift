import SwiftUI
import LedgerKit

struct ReconcileDest: Hashable {}

/// accounts whose statement / check day has passed: compare with the bank and write the assertions
struct ReconcileView: View {
    @EnvironmentObject var store: Store
    /// per account: nil = not answered, otherwise the bank's balance as typed
    @State private var bank: [String: String] = [:]
    @State private var matched: Set<String> = []
    @FocusState private var focus: String?

    var body: some View {
        List {
            if let L = store.L {
                let due = reconcileDue(L)
                if due.isEmpty {
                    Section {
                        Label(LS("没有待核对的账户"), systemImage: "checkmark.seal").foregroundStyle(Color.gain)
                    } footer: {
                        Text(LS("在「账户 → 编辑账户」中设置账单日或核对日的账户，每月这一天结束后会出现在这里。"))
                    }
                } else {
                    ForEach(due) { r in row(r, L) }
                    Section {
                        Button {
                            focus = nil
                            let items = answered(due)
                            Task { if await store.reconcile(items) { bank = [:]; matched = [] } }
                        } label: {
                            Text(answered(due).isEmpty ? LS("请先核对上面的账户") : LS("写入 %@ 条余额断言", answered(due).count))
                                .frame(maxWidth: .infinity).fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(answered(due).isEmpty)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    } footer: {
                        Text(LS("对照银行 App 中账单日 / 核对日当天结束时的余额（信用卡看账单）。一致就点「一致」；不一致就填银行的数，写入前先找出差额。断言日期为第二天，表示当天结束时的余额。"))
                    }
                }
            }
        }
        .navigationTitle(LS("核对余额"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
    }

    private func typed(_ r: ReconcileDue) -> Double? {
        guard let t = bank[r.id], !t.trimmed.isEmpty else { return nil }
        return evalAmount(t.replacingOccurrences(of: ",", with: ""))
    }

    /// the accounts answered so far, with the amount to assert
    private func answered(_ due: [ReconcileDue]) -> [(ReconcileDue, Double)] {
        due.compactMap { r in
            if let v = typed(r) { return (r, v) }
            return matched.contains(r.id) ? (r, r.ledger) : nil
        }
    }

    @ViewBuilder
    private func row(_ r: ReconcileDue, _ L: Ledger) -> some View {
        let isCard = r.account.hasPrefix("Liabilities:")
        let v = typed(r)
        let diff = v.map { $0 - r.ledger }
        Section {
            LabeledContent(LS("账本余额"), value: money(r.ledger, r.currency)).sensitive()
            HStack {
                Text(LS("银行余额"))
                TextField(isCard ? LS("欠款填负数") : LS("不一致时填写"), text: Binding(get: { bank[r.id] ?? "" }, set: { bank[r.id] = $0; if !$0.isEmpty { matched.remove(r.id) } }))
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focus, equals: r.id)
            }
            if let d = diff, abs(d) > 0.005 {
                Text(LS("与账本相差 %@：可能有交易记错或漏记，写入后提交前检查会提示", money(d, r.currency)))
                    .font(.caption).foregroundStyle(Color.warn).sensitive()
                NavigationLink(value: AccountDest(name: r.account)) { Text(LS("查看账户明细")) }
            } else if v == nil {
                Button {
                    focus = nil
                    if matched.contains(r.id) { matched.remove(r.id) } else { matched.insert(r.id) }
                } label: {
                    Label(LS("一致"), systemImage: matched.contains(r.id) ? "checkmark.circle.fill" : "circle")
                }
            } else {
                Label(LS("一致"), systemImage: "checkmark.circle.fill").foregroundStyle(Color.gain)
            }
        } header: {
            Text(accountTitle(L, r.account) + " · " + r.day + (isCard ? LS(" 账单日") : LS(" 核对日"))).textCase(nil)
        } footer: {
            if let last = r.lastChecked { Text(LS("上次核对 %@", last)) }
        }
    }
}

/// a line on the overview while some accounts wait for their check
struct ReconcileBanner: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if let L = store.L {
            let due = reconcileDue(L)
            if !due.isEmpty {
                Section {
                    NavigationLink(value: ReconcileDest()) {
                        Label(LS("%@ 个账户待核对余额", Set(due.map { $0.account }).count), systemImage: "checklist").foregroundStyle(Color.warn)
                    }
                }
            }
        }
    }
}
