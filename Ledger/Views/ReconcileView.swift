import SwiftUI
import LedgerKit

struct ReconcileDest: Hashable {}

/// accounts whose statement / check day has come: compare the bank app's current balance with the ledger's,
/// and when they agree, write the assertion for the start of that day
struct ReconcileView: View {
    @EnvironmentObject var store: Store
    /// the bank's current balance as typed, per account
    @State private var bank: [String: String] = [:]
    /// accounts confirmed equal without typing
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
                        Text(LS("在「账户 → 编辑账户」中设置账单日或核对日的账户，每月到了这一天会出现在这里。"))
                    }
                } else {
                    ForEach(due) { r in row(r, L) }
                    Section {
                        let items = agreed(due)
                        Button {
                            focus = nil
                            Task { if await store.reconcile(items.map { ($0, $0.ledger) }) { bank = [:]; matched = [] } }
                        } label: {
                            Text(items.isEmpty ? LS("一致的账户才会写入断言") : LS("写入 %@ 条余额断言", items.count))
                                .frame(maxWidth: .infinity).fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(items.isEmpty)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    } footer: {
                        Text(LS("填银行 App 现在显示的余额（信用卡填当前欠款，负数），和账本到今天为止的余额比较；什么时候核对都可以。一致时写入账单日 / 核对日的余额断言，金额为账本在那天开始时的余额。有差额时不写入：先补记或改正，一致后再写。"))
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

    /// accounts whose bank balance agrees with the ledger: typed and equal, or confirmed equal
    private func agreed(_ due: [ReconcileDue]) -> [ReconcileDue] {
        due.filter { r in
            if let v = typed(r) { return abs(v - r.now) < 0.005 }
            return matched.contains(r.id)
        }
    }

    @ViewBuilder
    private func row(_ r: ReconcileDue, _ L: Ledger) -> some View {
        let isCard = r.account.hasPrefix("Liabilities:")
        let v = typed(r)
        let diff = v.map { $0 - r.now }
        Section {
            LabeledContent(LS("账本当前余额"), value: money(r.now, r.currency)).sensitive()
            HStack {
                Text(LS("银行当前余额"))
                TextField(isCard ? LS("欠款填负数") : LS("不一致时填写"), text: Binding(get: { bank[r.id] ?? "" }, set: { bank[r.id] = $0; if !$0.isEmpty { matched.remove(r.id) } }))
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focus, equals: r.id)
            }
            if let d = diff, abs(d) > 0.005 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LS("相差 %@，暂不写入", money(d, r.currency))).font(.subheadline.weight(.semibold)).foregroundStyle(Color.warn).sensitive()
                    Text(LS("常见原因：漏记或记错的交易，银行自动扣的利息、年费、手续费，信用卡还在「待入账」的交易（入账后再对）。")).font(.caption).foregroundStyle(.secondary)
                }
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
            VStack(alignment: .leading, spacing: 2) {
                Text(LS("将写入 %@ 的断言 %@", r.day, money(r.ledger, r.currency))
                     + (r.since > 0 ? LS("（之后已记 %@ 笔，合计 %@）", r.since, money(r.sinceTotal, r.currency)) : ""))
                if let last = r.lastChecked { Text(LS("上次核对 %@", last)) }
            }
            .sensitive()
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
