import SwiftUI
import UIKit
import LedgerKit

/// where a bill stands, in words and colour: 已还清, 已还最低, n 天后到期 or 已逾期
struct CardStatusLook {
    let text: String
    let color: Color
    let icon: String

    init(_ c: CardCycle, today: String) {
        let days = daysBetween(today, c.due)
        switch c.status(today: today) {
        case .settled: (text, color, icon) = (LS("已还清"), .gain, "checkmark.circle")
        case .minimumPaid: (text, color, icon) = (LS("已还最低"), Color.warn, "checkmark.circle")
        case .overdue: (text, color, icon) = (LS("已逾期"), .loss, "exclamationmark.circle")
        case .due:
            (text, color, icon) = (days == 0 ? LS("今天到期") : LS("%@天后到期", days), days <= 7 ? Color.warn : .secondary, "clock")
        }
    }
}

/// a card's first screen: what is still to pay on its bill, when, and 记录还款; the bill against what was paid
struct CardHeroSection: View {
    @Environment(Store.self) var store
    let cycle: CardCycle
    @State private var billing = false
    @State private var documents = false

    var body: some View {
        let today = Day.today()
        let c = cycle
        let tail = store.repoConfig?.scanCards?.first { $0.value == c.account && $0.key.count == 4 && $0.key.allSatisfy(\.isNumber) }?.key
        let look = CardStatusLook(c, today: today)
        Section {
            VStack(alignment: .leading, spacing: AppSpacing.control) {
                HStack(spacing: AppSpacing.icon) {
                    IconBadge(symbol: "creditcard.fill", color: .red, size: 34)
                    Text(LS("本期账单") + (tail.map { " · " + LS("尾号 %@", $0) } ?? "")).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: AppSpacing.control) {
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                        Text(LS("剩余应还")).font(.subheadline).foregroundStyle(.secondary)
                        Text(money(c.remaining, c.currency)).heroAmount().monospacedDigit()
                            .rollingNumber(c.remaining)
                            .lineLimit(1).minimumScaleFactor(0.6).sensitive()
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: AppSpacing.icon) {
                        Label(look.text, systemImage: look.icon).labelStyle(ControlLabelStyle())
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, AppSpacing.icon).padding(.vertical, AppSpacing.icon)
                            .foregroundStyle(look.color)
                            .background(look.color.soft, in: Capsule())
                        Text(LS("还款日 %@", (c.dueEstimated ? "≈ " : "") + shortDay(c.due))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    VStack(spacing: AppSpacing.detail) {
                        Text(LS("本期账单")).font(.caption).foregroundStyle(.secondary)
                        Text(money(c.statementAmount, c.currency)).font(.callout.weight(.semibold).monospacedDigit()).sensitive()
                    }
                    .frame(maxWidth: .infinity)
                    Divider().frame(height: 32)
                    VStack(spacing: AppSpacing.detail) {
                        Text(LS("最低还款")).font(.caption).foregroundStyle(.secondary)
                        Text((c.minimumEstimated ? "≈ " : "") + money(c.minimum, c.currency)).font(.callout.weight(.semibold).monospacedDigit()).sensitive()
                    }
                    .frame(maxWidth: .infinity)
                    Divider().frame(height: 32)
                    VStack(spacing: AppSpacing.detail) {
                        Text(LS("已还")).font(.caption).foregroundStyle(.secondary)
                        Text(money(c.paid, c.currency)).font(.callout.weight(.semibold).monospacedDigit()).sensitive()
                    }
                    .frame(maxWidth: .infinity)
                }
                if c.status(today: today) == .minimumPaid {
                    Label(LS("已还到最低还款额，不算逾期；剩余 %@ 未还会按银行规定计息。", money(c.remaining, c.currency)), systemImage: "info.circle").labelStyle(ControlLabelStyle())
                        .font(.footnote).foregroundStyle(.secondary).sensitive()
                } else if c.status(today: today) == .overdue {
                    Label(LS("还款日已过，最低还款还差 %@。", money(c.minimumRemaining, c.currency)), systemImage: "exclamationmark.triangle").labelStyle(ControlLabelStyle())
                        .font(.footnote).foregroundStyle(Color.loss).sensitive()
                }
                Button { documents = true } label: {
                    Label(LS("查看 / 添加对账单"), systemImage: "doc.text.magnifyingglass").labelStyle(ControlLabelStyle())
                }
                .buttonStyle(.borderless)
                // System bordered capsules draw a drop shadow outside their frames. Flatten and
                // clip it to the button row so it cannot darken the card's bottom edge or the
                // reminder row. Layout size is unchanged, so the buttons stay the same height.
                ActionRow(size: .small, items: cardBillActions(c))
                    .compositingGroup()
                    .clipped()
            }
            .padding(AppSpacing.content)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .cardRow()
            .listRowSeparator(.hidden, edges: .bottom)
            .background {
                ListRowBottomShadowClamp().allowsHitTesting(false)
            }
            .entryActions(c.bill, edit: { billing = true })
            .sheet(isPresented: $billing) { CardBillSheet(cycle: c) }
            .sheet(isPresented: $documents) { AccountDocumentsSheet(account: c.account) }
            .task { if store.demoEnv["LEDGER_DOCUMENTS"] != nil { try? await Task.sleep(nanoseconds: 700_000_000); documents = true } }
            .task { if store.demoEnv["LEDGER_CARD_BILL"] != nil { try? await Task.sleep(nanoseconds: 700_000_000); billing = true } }
            reminderBanner(c)
        } footer: {
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                if c.dueEstimated { Text(LS("未设置还款日，按账单日后 20 天估算。可在「编辑账户」中设置。")) }
                if c.bill == nil {
                    Text(LS("本期账单按账本算出，最低还款按其 %@ 估算（开户指令的 min_payment_rate 可改）。分期或与银行不一致时，点「填写本期账单」照银行账单填写。",
                            String(format: "%.0f%%", c.statementAmount > 0 ? c.minimum / c.statementAmount * 100 : defaultMinPaymentRate * 100)))
                } else if c.minimumEstimated {
                    Text(LS("本期账单按银行账单；没填最低还款，按 %@ 估算。",
                            String(format: "%.0f%%", c.statementAmount > 0 ? c.minimum / c.statementAmount * 100 : defaultMinPaymentRate * 100)))
                }
            }
        }
    }

    /// 填写/修改本期账单 is the outline. 记录还款, when the card still owes money, is the filled action.
    private func cardBillActions(_ c: CardCycle) -> [ActionRow.Item] {
        var items = [ActionRow.Item(
            title: c.bill == nil ? LS("填写本期账单") : LS("修改本期账单"),
            systemImage: "doc.text"
        ) { billing = true }]
        if c.balance > 0.005 {
            items.append(ActionRow.Item(title: LS("记录还款"), systemImage: "arrow.up.right", emphasis: .primary) {
                store.repaying = c
            })
        }
        return items
    }

    /// whether the bill will be reminded of; tap to change it in 设置
    private func reminderBanner(_ c: CardCycle) -> some View {
        let on = Reminders.enabled
        return Button { store.showSettings = true } label: {
            HStack(spacing: AppSpacing.icon) {
                Image(systemName: on ? "calendar.badge.clock" : "bell.slash").foregroundStyle(Color.warn)
                Text(on ? LS("已开启还款提醒 · 提前 %@ 天", Reminders.billDays) : LS("还款提醒未开启"))
                    .font(.subheadline).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.control)
            .background(Color.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardRow()
        .listRowSeparator(.hidden, edges: .top)
    }

    private func shortDay(_ d: String) -> String {
        LS("%@月%@日", String(Int(d.dropFirst(5).prefix(2)) ?? 0), String(Int(d.suffix(2)) ?? 0))
    }
}

/// The bill card is a list row with a clear row background. The row's own drop shadow
/// still falls on the next row (还款提醒). This view only clears that cell shadow.
private struct ListRowBottomShadowClamp: UIViewRepresentable {
    func makeUIView(context: Context) -> ListRowBottomShadowClampView {
        let view = ListRowBottomShadowClampView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ uiView: ListRowBottomShadowClampView, context: Context) {
        uiView.clamp()
    }
}

private final class ListRowBottomShadowClampView: UIView {
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        clamp()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        clamp()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clamp()
    }

    func clamp() {
        var ancestor: UIView? = superview
        while let view = ancestor {
            if let cell = view as? UICollectionViewCell {
                clear(cell.layer)
                if let background = cell.backgroundView { clear(background.layer) }
                return
            }
            if let cell = view as? UITableViewCell {
                clear(cell.layer)
                if let background = cell.backgroundView { clear(background.layer) }
                return
            }
            ancestor = view.superview
        }
    }

    private func clear(_ layer: CALayer) {
        guard layer.shadowOpacity != 0 || layer.shadowRadius != 0 || layer.shadowOffset != .zero else { return }
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowOffset = .zero
    }
}

/// 额度与账单: the credit left, what is not billed yet, the next statement, all that is owed
struct CardLimitSection: View {
    let cycle: CardCycle
    var body: some View {
        let c = cycle
        Section(LS("额度与账单")) {
            if let a = c.available, let l = c.limit, l > 0 {
                VStack(alignment: .leading, spacing: AppSpacing.icon) {
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
    @Environment(Store.self) var store
    @State private var editingBill: CardCycle?
    let L: Ledger

    var body: some View {
        let today = Day.today()
        let soon = Day.shift(today, 15)
        let due = cardCycles(L, today: today).filter { !$0.settled && ($0.overdue(today: today) || $0.due <= soon) }.sorted { $0.due < $1.due }
        if !due.isEmpty {
            Section(LS("信用卡待还")) {
                ForEach(due) { c in
                    HStack(spacing: AppSpacing.control) {
                        NavigationLink(value: AccountDest(name: c.account)) {
                            HStack(spacing: AppSpacing.icon) {
                                IconBadge(symbol: "creditcard.fill", color: c.overdue(today: today) ? .red : Color.warn, size: 28)
                                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                    Text(accountTitle(L, c.account)).lineLimit(1)
                                    Text(dueLine(c, today))
                                        .font(.caption).foregroundStyle(c.overdue(today: today) ? Color.loss : Color.secondary)
                                }
                                Spacer()
                                Text(money(c.remaining, c.currency)).monospacedDigit().sensitive()
                            }
                        }
                        Button { store.repaying = c } label: { Label(LS("还款"), systemImage: "arrow.up.right").labelStyle(ControlLabelStyle()) }.rowButton(filled: true)
                    }
                    .entryActions(c.bill, edit: { editingBill = c })
                }
            }
            .sheet(item: $editingBill) { CardBillSheet(cycle: $0) }
        }
    }
}

extension CardDueSection {
    private func dueLine(_ c: CardCycle, _ today: String) -> String {
        switch c.status(today: today) {
        case .overdue: return LS("%@ 到期 · 已逾期", c.due)
        case .minimumPaid: return LS("%@ 到期 · 已还最低", c.due)
        default: return LS("%@ 到期 · %@", c.due, daysText(c.due, today: today))
        }
    }
}

/// 填写本期账单: the bank's statement amount and minimum payment for the latest statement, as a card-bill directive
struct CardBillSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let cycle: CardCycle
    @State private var amount = ""
    @State private var minimum = ""
    @State private var deletion: EntryDeletion?
    @State private var saving = false
    @State private var closeRequested = false
    @State private var baseline: [String]?

    private var text: String? {
        guard let a = evalAmount(amount), a >= 0 else { return nil }
        let m = minimum.trimmingCharacters(in: .whitespaces).isEmpty ? nil : evalAmount(minimum)
        if let m = m, m > a { return nil }
        return cardBillText(card: cycle.account, statement: cycle.statement, amount: a, minimum: m, currency: cycle.currency)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(LS("信用卡"), value: acctDisplay(cycle.account))
                    LabeledContent(LS("账单日"), value: cycle.statement)
                    LabeledContent(LS("本期应还") + " " + cycle.currency) {
                        TextField("0.00", text: $amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing).font(.body.monospacedDigit())
                    }
                    LabeledContent(LS("最低还款") + " " + cycle.currency) {
                        TextField(LS("可不填"), text: $minimum).keyboardType(.decimalPad).multilineTextAlignment(.trailing).font(.body.monospacedDigit())
                    }
                } footer: {
                    Text(LS("照银行账单填写。填了以后，这一期的应还和最低还款以它为准（分期只算本期应还的部分）；还到最低还款额就不算逾期。"))
                }
                if let t = text {
                    Section(LS("将写入")) { MonoText(text: t) }
                }
                if cycle.bill != nil {
                    Section {
                        Button(role: .destructive) {
                            if let entry = cycle.bill { deletion = EntryDeletion(entry, ledgerID: store.cfg.id, onDeleted: { dismiss() }) }
                        } label: { Label(LS("删除这期账单记录"), systemImage: "trash").labelStyle(ControlLabelStyle()) }
                    } footer: {
                        Text(LS("删除后按账本算出的金额估算。"))
                    }
                }
            }
            .keyboardDone()
            .navigationTitle(LS("本期账单"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { closeRequested = true } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { SaveLabel() }.disabled(text == nil || saving)
                }
            }
            .entryDeletion($deletion)
            .disabled(saving)
            .protectUnsavedChanges(dirty: baseline.map { $0 != [amount, minimum] } ?? false,
                busy: saving, requested: $closeRequested, discard: { dismiss() }, close: { dismiss() })
            .onAppear {
                guard baseline == nil else { return }
                amount = jsNumberString(cycle.statementAmount)
                minimum = cycle.minimumEstimated ? "" : jsNumberString(cycle.minimum)
                baseline = [amount, minimum]
            }
            .onChange(of: store.cfg.id) { _, _ in dismiss() }
        }
    }

    private func save() {
        guard !saving, let t = text else { return }
        saving = true
        let ledgerID = store.cfg.id
        let label = LS("本期账单：%@ %@", acctLabel(cycle.account), cycle.statement)
        Task {
            defer { saving = false }
            guard store.cfg.id == ledgerID else { return }
            let ok: Bool
            if let e = cycle.bill {
                ok = await store.replaceDirective(e, with: t, summary: label, word: LS("已更新本期账单"))
            } else {
                ok = await store.addCardBill(t, label: label)
            }
            if ok { dismiss() }
        }
    }
}

struct RepaySheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let cycle: CardCycle
    @State private var amount = ""
    @State private var from = ""
    @State private var date = Day.today()
    @State private var loaded = false
    @State private var saving = false
    @State private var closeRequested = false
    @State private var baseline: [String]?
    private var state: [String] { [amount, from, date] }

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
                        if cycle.minimumRemaining > 0.005 && abs(cycle.minimumRemaining - cycle.remaining) > 0.005 {
                            Chip(label: LS("最低还款 %@", money(cycle.minimumRemaining, cycle.currency)), selected: evalAmount(amount) == cycle.minimumRemaining) {
                                amount = jsNumberString(cycle.minimumRemaining)
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
            .disabled(saving)
            .protectUnsavedChanges(dirty: baseline.map { $0 != state } ?? false, busy: saving,
                requested: $closeRequested, discard: { dismiss() }, close: { dismiss() })
            .onChange(of: store.cfg.id) { _, _ in dismiss() }
            .keyboardDone()
            .navigationTitle(LS("信用卡还款"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { closeRequested = true } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { SaveLabel() }.disabled((evalAmount(amount) ?? 0) <= 0 || from.isEmpty || saving)
                }
            }
            .onAppear {
                guard !loaded, let L = store.L else { return }
                loaded = true
                let a = cycle.remaining > 0.005 ? cycle.remaining : cycle.balance
                amount = a > 0 ? jsNumberString(a) : ""
                from = usualRepaymentAccount(cycle.account, L) ?? store.D?.rankAccounts(["Assets:"]).first ?? ""
                baseline = state
            }
        }
    }

    private func save() {
        guard !saving, let a = evalAmount(amount), a.isFinite, a > 0, let L = store.L else { return }
        guard accountTakes(from, cycle.currency, L) else { store.show(LS("付款账户不支持还款币种，请更换账户。")); return }
        let text = repaymentText(card: cycle.account, from: from, amount: a, currency: cycle.currency, date: date)
        guard let ops = store.makeOps(text, extra: OpExtra(label: LS("信用卡还款：%@ %@", acctLabel(cycle.account), money(a, cycle.currency))), single: true) else { return }
        let ledgerID = store.cfg.id
        saving = true
        Task {
            defer { saving = false }
            guard store.cfg.id == ledgerID else { return }
            await store.commit(ops, word: LS("已记录还款"), closing: { dismiss() })
        }
    }
}
