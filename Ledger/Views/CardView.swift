import SwiftUI
import LedgerKit

/// a card's first screen: what is still to pay on its bill, when, and 记录还款; the bill against what was paid
struct CardHeroSection: View {
    @EnvironmentObject var store: Store
    let cycle: CardCycle

    var body: some View {
        let today = Day.today()
        let c = cycle
        let days = daysBetween(today, c.due)
        let tail = store.repoConfig?.scanCards?.first { $0.value == c.account && $0.key.count == 4 && $0.key.allSatisfy(\.isNumber) }?.key
        let tone: Color = c.overdue(today: today) ? .loss : c.settled ? .gain : (days <= 7 ? .orange : .secondary)
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    IconBadge(symbol: "creditcard.fill", color: .red, size: 34)
                    Text(LS("本期账单") + (tail.map { " · " + LS("尾号 %@", $0) } ?? "")).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LS("剩余应还")).font(.subheadline).foregroundStyle(.secondary)
                        Text(money(c.remaining, c.currency)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6).sensitive()
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 6) {
                        Label(c.settled ? LS("已还清") : c.overdue(today: today) ? LS("已逾期") : days == 0 ? LS("今天到期") : LS("%@天后到期", days),
                              systemImage: c.settled ? "checkmark.circle" : "clock")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .foregroundStyle(tone)
                            .background(tone.opacity(0.14), in: Capsule())
                        Text(LS("还款日 %@", (c.dueEstimated ? "≈ " : "") + shortDay(c.due))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    VStack(spacing: 3) {
                        Text(LS("本期账单")).font(.caption).foregroundStyle(.secondary)
                        Text(money(c.statementAmount, c.currency)).font(.callout.weight(.semibold).monospacedDigit()).sensitive()
                    }
                    .frame(maxWidth: .infinity)
                    Divider().frame(height: 32)
                    VStack(spacing: 3) {
                        Text(LS("已还")).font(.caption).foregroundStyle(.secondary)
                        Text(money(c.paid, c.currency)).font(.callout.weight(.semibold).monospacedDigit()).sensitive()
                    }
                    .frame(maxWidth: .infinity)
                }
                if c.balance > 0.005 {
                    Button { store.repaying = c } label: {
                        Text(LS("记录还款")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(.jade).controlSize(.large)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .cardRow()
            reminderBanner(c)
        } footer: {
            if c.dueEstimated { Text(LS("未设置还款日，按账单日后 20 天估算。可在「编辑账户」中设置。")) }
        }
    }

    /// whether the bill will be reminded of; tap to change it in 设置
    private func reminderBanner(_ c: CardCycle) -> some View {
        let on = Reminders.enabled
        return Button { store.showSettings = true } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "calendar.badge.clock" : "bell.slash").foregroundStyle(Color.orange)
                Text(on ? LS("已开启还款提醒 · 提前 %@ 天", Reminders.billDays) : LS("还款提醒未开启"))
                    .font(.subheadline).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardRow()
    }

    private func shortDay(_ d: String) -> String {
        LS("%@月%@日", String(Int(d.dropFirst(5).prefix(2)) ?? 0), String(Int(d.suffix(2)) ?? 0))
    }
}

/// 额度与账单: the credit left, what is not billed yet, the next statement, all that is owed
struct CardLimitSection: View {
    let cycle: CardCycle
    var body: some View {
        let c = cycle
        Section(LS("额度与账单")) {
            if let a = c.available, let l = c.limit, l > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent(LS("可用额度"), value: money(a, c.currency) + " / " + money(l, c.currency, 0)).sensitive()
                    ProgressView(value: max(0, min(1, a / l))).tint(.jade)
                }
            }
            LabeledContent(LS("未出账"), value: money(c.unbilled, c.currency)).sensitive()
            LabeledContent(LS("下个账单日"), value: c.nextStatement)
            LabeledContent(LS("当前欠款"), value: money(c.balance, c.currency)).sensitive()
        }
    }
}

/// cards with a bill due soon (or overdue), for the overview
struct CardDueSection: View {
    @EnvironmentObject var store: Store
    let L: Ledger

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
                                    Text(accountTitle(L, c.account)).lineLimit(1)
                                    Text(c.overdue(today: today) ? LS("%@ 到期 · 已逾期", c.due) : LS("%@ 到期 · %@", c.due, daysText(c.due, today: today)))
                                        .font(.caption).foregroundStyle(c.overdue(today: today) ? Color.loss : Color.secondary)
                                }
                                Spacer()
                                Text(money(c.remaining, c.currency)).monospacedDigit().sensitive()
                            }
                        }
                        Button(LS("还款")) { store.repaying = c }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
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
