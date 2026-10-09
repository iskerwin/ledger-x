import SwiftUI
import LedgerKit

/// "账单日 5 日" … for the latest statement of a card
struct CardBillSection: View {
    @EnvironmentObject var store: Store
    let cycle: CardCycle
    @State private var repaying = false

    var body: some View {
        let today = Day.today()
        let c = cycle
        Section {
            HStack(alignment: .top) {
                Figure(label: LS("%@ 账单", c.statement), value: money(c.statementAmount, c.currency))
                Spacer()
                Figure(label: LS("已还"), value: money(c.paid, c.currency))
                Spacer()
                Figure(label: LS("剩余应还"), value: money(c.remaining, c.currency),
                       color: c.overdue(today: today) ? .loss : c.settled ? .gain : .primary, alignment: .trailing)
            }
            .padding(.vertical, 4)
            LabeledContent(LS("还款日")) {
                Text(c.settled ? LS("%@ · 已还清", c.due)
                     : c.overdue(today: today) ? LS("%@ · 已逾期", c.due)
                     : (c.dueEstimated ? "≈ " : "") + c.due + " · " + daysText(c.due, today: today))
                    .foregroundStyle(c.overdue(today: today) ? Color.loss : c.settled ? Color.gain : Color.secondary)
            }
            LabeledContent(LS("本期未出账"), value: money(c.unbilled, c.currency)).sensitive()
            LabeledContent(LS("下个账单日"), value: c.nextStatement)
            if let a = c.available, let l = c.limit {
                LabeledContent(LS("可用额度"), value: money(a, c.currency) + " / " + money(l, c.currency, 0)).sensitive()
            }
            if c.balance > 0.005 {
                Button { repaying = true } label: { Label(LS("还款"), systemImage: "arrow.uturn.left.circle") }
            }
        } header: {
            Text(LS("信用卡账单"))
        } footer: {
            if c.dueEstimated { Text(LS("未设置还款日，按账单日后 20 天估算。可在「编辑账户」中设置。")) }
        }
        .sheet(isPresented: $repaying) { RepaySheet(cycle: c) }
    }
}

/// cards with a bill due soon (or overdue), for the overview
struct CardDueSection: View {
    @EnvironmentObject var store: Store
    let L: Ledger
    @State private var repaying: CardCycle?

    var body: some View {
        let today = Day.today()
        let soon = Day.shift(today, 15)
        let due = cardCycles(L, today: today).filter { !$0.settled && ($0.overdue(today: today) || $0.due <= soon) }.sorted { $0.due < $1.due }
        if !due.isEmpty {
            Section(LS("信用卡待还")) {
                ForEach(due) { c in
                    HStack(spacing: 12) {
                        NavigationLink(value: AccountDest(name: c.account)) {
                            HStack(spacing: 12) {
                                IconBadge(symbol: "creditcard.fill", color: c.overdue(today: today) ? .red : .orange, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(acctLabel(c.account))
                                    Text(c.overdue(today: today) ? LS("%@ 到期 · 已逾期", c.due) : LS("%@ 到期 · %@", c.due, daysText(c.due, today: today)))
                                        .font(.caption).foregroundStyle(c.overdue(today: today) ? Color.loss : Color.secondary)
                                }
                                Spacer()
                                Text(money(c.remaining, c.currency)).monospacedDigit().sensitive()
                            }
                        }
                        Button(LS("还款")) { repaying = c }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
            .sheet(item: $repaying) { RepaySheet(cycle: $0) }
        }
    }
}

struct RepaySheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let cycle: CardCycle
    @State private var amount = ""
    @State private var from = ""
    @State private var date = Day.today()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(LS("信用卡"), value: acctDisplay(cycle.account))
                    LabeledContent(LS("金额") + " " + cycle.currency) {
                        TextField("0.00", text: $amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing).font(.body.monospacedDigit())
                    }
                    ChipRow {
                        if cycle.remaining > 0.005 {
                            Chip(label: LS("本期应还 %@", money(cycle.remaining, cycle.currency)), selected: evalAmount(amount) == cycle.remaining) {
                                amount = jsNumberString(cycle.remaining)
                            }
                        }
                        if cycle.balance > 0.005 && abs(cycle.balance - cycle.remaining) > 0.005 {
                            Chip(label: LS("全部欠款 %@", money(cycle.balance, cycle.currency)), selected: evalAmount(amount) == cycle.balance) {
                                amount = jsNumberString(cycle.balance)
                            }
                        }
                    }
                    if let D = store.D {
                        AccountField(label: LS("付款账户"), prefixes: ["Assets:"], chips: Array(D.rankAccounts(["Assets:"]).prefix(4)), value: $from)
                    }
                    DateField(value: $date)
                }
                if let a = evalAmount(amount), a > 0, !from.isEmpty {
                    Section(LS("将写入")) { MonoText(text: repaymentText(card: cycle.account, from: from, amount: a, currency: cycle.currency, date: date)) }
                }
            }
            .keyboardDone()
            .navigationTitle(LS("信用卡还款"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LS("保存")) { save() }.fontWeight(.semibold).disabled((evalAmount(amount) ?? 0) <= 0 || from.isEmpty)
                }
            }
            .onAppear {
                guard !loaded, let L = store.L else { return }
                loaded = true
                let a = cycle.remaining > 0.005 ? cycle.remaining : cycle.balance
                amount = a > 0 ? jsNumberString(a) : ""
                from = usualRepaymentAccount(cycle.account, L) ?? store.D?.rankAccounts(["Assets:"]).first ?? ""
            }
        }
    }

    private func save() {
        guard let a = evalAmount(amount), a > 0 else { return }
        let text = repaymentText(card: cycle.account, from: from, amount: a, currency: cycle.currency, date: date)
        guard let ops = store.makeOps(text, extra: OpExtra(label: LS("信用卡还款：%@ %@", acctLabel(cycle.account), money(a, cycle.currency))), single: true) else { return }
        Task { await store.commit(ops, word: LS("已记录还款"), closing: { dismiss() }) }
    }
}
