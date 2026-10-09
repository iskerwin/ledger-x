import SwiftUI
import LedgerKit

struct SubscriptionsDest: Hashable {}

/// "3 天后" / "今天" / "已过 2 天"
func daysText(_ date: String, today: String = Day.today()) -> String {
    guard let a = Day.date(today), let b = Day.date(date) else { return date }
    let n = Int((b.timeIntervalSince(a) / 86400).rounded())
    switch n {
    case 0: return LS("今天")
    case 1: return LS("明天")
    case 2...: return LS("%@ 天后", n)
    default: return LS("已过 %@ 天", -n)
    }
}

// MARK: - recording a charge

extension Store {
    /// write the charge as a transaction tagged with `subscription:` metadata
    func recordSubscription(_ s: Subscription, date: String) async {
        guard !s.account.isEmpty, !s.funding.isEmpty else {
            show(LS("请先为「%@」设置支出科目和付款账户", s.name))
            return
        }
        func q(_ x: String) -> String { "\"" + x.replacingOccurrences(of: "\"", with: "'") + "\"" }
        let payee = s.payee.isEmpty ? s.name : s.payee
        let narration = s.payee.isEmpty || s.payee == s.name ? "" : s.name
        let text = """
        \(date) * \(q(payee)) \(q(narration))
          subscription: \(q(s.name))
          \(s.account)  \(toFixed(s.amount, 2)) \(s.currency)
          \(s.funding)
        """
        guard let ops = makeOps(alignText(text), extra: OpExtra(label: LS("订阅扣费：%@ %@", s.name, money(s.amount, s.currency))), single: true) else { return }
        await commit(ops, word: LS("已记录 %@", s.name))
    }
}

// MARK: - overview section

struct SubscriptionOverviewSection: View {
    @EnvironmentObject var store: Store
    let L: Ledger

    var body: some View {
        let subs = subscriptions(L).filter { $0.status == .active }
        let due = subscriptionsDue(L)
        let today = Day.today()
        let monthly = subs.reduce(0.0) { $0 + (toCNY(L, $1.monthly, $1.currency) ?? 0) }
        let upcoming = subs.map { ($0, $0.due(onOrAfter: today)) }.min { $0.1 < $1.1 }
        Section {
            ForEach(due) { d in SubDueRow(due: d) }
            NavigationLink(value: SubscriptionsDest()) {
                HStack(spacing: 12) {
                    IconBadge(symbol: "repeat", color: .purple, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subs.isEmpty ? LS("订阅管理") : LS("%@ 个订阅 · 月均 %@", subs.count, money(monthly, L.base, 0)))
                            .sensitive()
                        if let u = upcoming {
                            Text(LS("下次：%@ · %@", u.0.name, daysText(u.1, today: today))).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(LS("记录周期扣费，到期提醒并一键入账")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text(LS("订阅"))
        }
    }
}

struct SubDueRow: View {
    @EnvironmentObject var store: Store
    let due: SubDue
    @State private var busy = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(due.sub.name)
                Text(LS("%@ 应扣费 · 未入账", due.date)).font(.caption).foregroundStyle(Color.warn)
            }
            Spacer()
            Text(money(due.sub.amount, due.sub.currency)).monospacedDigit().sensitive()
            Button {
                busy = true
                Task { await store.recordSubscription(due.sub, date: due.date); busy = false }
            } label: {
                Text(LS("记一笔")).font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(busy)
        }
    }
}

// MARK: - list

struct SubscriptionsView: View {
    @EnvironmentObject var store: Store
    @State private var editing: SubDraft?

    var body: some View {
        Group {
            if let L = store.L { list(L) } else { ProgressView() }
        }
        .navigationTitle(LS("订阅管理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = SubDraft(currency: store.L?.base ?? "CNY") } label: { Image(systemName: "plus") }
                    .accessibilityLabel(LS("添加订阅"))
            }
        }
        .sheet(item: $editing) { SubEditSheet(draft: $0) }
        .task {
            if store.demoEnv["LEDGER_SUB_EDIT"] != nil, let L = store.L, let s = subscriptions(L).first { editing = SubDraft(s) }
        }
    }

    private func list(_ L: Ledger) -> some View {
        let all = subscriptions(L)
        let today = Day.today()
        let active = all.filter { $0.status == .active }.sorted { $0.due(onOrAfter: today) < $1.due(onOrAfter: today) }
        let inactive = all.filter { $0.status != .active }
        let due = subscriptionsDue(L, today: today)
        let monthly = active.reduce(0.0) { $0 + (toCNY(L, $1.monthly, $1.currency) ?? 0) }
        let cands = subscriptionCandidates(L, today: today)
        return List {
            Section {
                Card {
                    HStack(alignment: .top) {
                        Figure(label: LS("月均"), value: money(monthly, L.base))
                        Spacer()
                        Figure(label: LS("每年"), value: money(monthly * 12, L.base, 0))
                        Spacer()
                        Figure(label: LS("订阅中"), value: "\(active.count)", alignment: .trailing)
                    }
                }
                .cardRow()
            }
            if !due.isEmpty {
                Section(LS("待记账")) { ForEach(due) { SubDueRow(due: $0) } }
            }
            Section {
                if active.isEmpty { Text(LS("还没有订阅。点右上角 +，或在交易详情里选择「加入订阅管理」。")).foregroundStyle(.secondary) }
                ForEach(active) { s in row(s, L, today) }
            } header: {
                Text(LS("订阅中"))
            } footer: {
                Text(LS("订阅写在账本中：custom \"subscription\" 名称 周期 金额。赠送或延长时设置「下次扣费日」，之后按原周期继续计算。"))
            }
            if !inactive.isEmpty {
                Section(LS("已暂停 / 已取消")) { ForEach(inactive) { s in row(s, L, today) } }
            }
            if !cands.isEmpty {
                Section {
                    ForEach(cands) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.payee)
                                Text(LS("%@ · 近一年 %@ 笔 · 最近 %@", c.period.name, c.count, c.last)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(money(c.amount, c.currency)).monospacedDigit().sensitive()
                            Button(LS("添加")) { editing = SubDraft(c) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                } header: {
                    Text(LS("发现的周期性支出"))
                }
            }
        }
        .listSectionSpacing(.compact)
    }

    private func row(_ s: Subscription, _ L: Ledger, _ today: String) -> some View {
        let next = s.due(onOrAfter: today)
        return Button { editing = SubDraft(s) } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: s.status == .active ? "repeat" : s.status == .paused ? "pause" : "xmark", color: s.status == .active ? .purple : .gray, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name)
                    Group {
                        if s.status == .active {
                            Text(s.period.name + " · " + LS("下次 %@（%@）", next, daysText(next, today: today)))
                        } else {
                            Text(s.period.name + " · " + s.status.name)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let n = s.next, n > today, s.status == .active {
                        Text(LS("延长至 %@，之后按%@计", n, s.period.name)).font(.caption2).foregroundStyle(Color.jade)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(money(s.amount, s.currency)).monospacedDigit()
                    if s.period != .monthly {
                        Text(LS("月均 %@", money(s.monthly, s.currency))).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .sensitive()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            if s.status == .active {
                Button(LS("记一笔")) { Task { await store.recordSubscription(s, date: s.due(onOrBefore: today) ?? today) } }.tint(Color.jade)
            }
        }
    }
}

// MARK: - edit

struct SubDraft: Identifiable {
    let id = UUID()
    var name = ""
    var amount = ""
    var currency = "CNY"
    var period = SubPeriod.monthly
    var custom = false
    var start = Day.today()
    var account = ""
    var funding = ""
    var payee = ""
    var extended = false
    var next = Day.today()
    var status = SubStatus.active
    var original: Entry?

    init(currency: String) { self.currency = currency }

    init(_ s: Subscription) {
        name = s.name; amount = jsNumberString(s.amount); currency = s.currency; period = s.period
        custom = !SubPeriod.presets.contains(s.period)
        start = s.start; account = s.account; funding = s.funding; payee = s.payee
        extended = s.next != nil
        next = s.next ?? s.due(onOrAfter: Day.today())
        status = s.status; original = s.entry
    }

    init(_ c: SubCandidate) {
        name = c.payee; amount = jsNumberString(c.amount); currency = c.currency; period = c.period
        start = c.last; account = c.account; funding = c.funding; payee = c.payee
    }

    /// from a transaction: its expense leg, funding leg and date
    init(_ t: Entry, _ L: Ledger) {
        name = t.payee.isEmpty ? t.narration : t.payee
        payee = t.payee
        start = t.date
        if let e = t.postings.first(where: { $0.account.hasPrefix("Expenses:") }) {
            account = e.account
            amount = jsNumberString(abs(e.units ?? 0))
            currency = e.currency ?? L.base
        }
        funding = t.postings.first { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }?.account ?? ""
    }

    var sub: Subscription? {
        guard let a = evalAmount(amount), a > 0, !name.trimmed.isEmpty else { return nil }
        return Subscription(name: name.trimmed, amount: a, currency: currency.trimmed.uppercased(), period: period, start: start,
                            account: account, funding: funding, payee: payee.trimmed,
                            next: extended && next > start ? next : nil, status: status)
    }
}

struct SubEditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var draft: SubDraft
    @State private var picking: PickTarget?
    @State private var confirmDelete = false

    enum PickTarget: String, Identifiable { case account, funding; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(LS("名称")) {
                        TextField(LS("如 iCloud+、Netflix"), text: $draft.name).multilineTextAlignment(.trailing)
                    }
                    LabeledContent(LS("金额")) {
                        HStack(spacing: 6) {
                            TextField("0.00", text: $draft.amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing).font(.body.monospacedDigit())
                            TextField("CNY", text: $draft.currency).frame(width: 52).multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled().foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent(LS("商户")) {
                        TextField(LS("可选"), text: $draft.payee).multilineTextAlignment(.trailing)
                    }
                }
                Section {
                    Picker(LS("周期"), selection: Binding(get: { draft.custom ? nil : draft.period }, set: { v in
                        if let v = v { draft.period = v; draft.custom = false } else { draft.custom = true }
                    })) {
                        ForEach(SubPeriod.presets, id: \.self) { Text($0.name).tag(Optional($0)) }
                        Text(LS("自定义")).tag(SubPeriod?.none)
                    }
                    if draft.custom {
                        Stepper(LS("每 %@", draft.period.n), value: $draft.period.n, in: 1...365)
                        Picker(LS("单位"), selection: $draft.period.unit) {
                            Text(LS("天")).tag(PeriodUnit.day)
                            Text(LS("周")).tag(PeriodUnit.week)
                            Text(LS("月")).tag(PeriodUnit.month)
                            Text(LS("年")).tag(PeriodUnit.year)
                        }
                        .pickerStyle(.segmented)
                    }
                    DatePicker(LS("首次扣费"), selection: dateBinding($draft.start), displayedComponents: .date)
                    Toggle(LS("赠送 / 延长周期"), isOn: $draft.extended.animation())
                    if draft.extended {
                        DatePicker(LS("下次扣费日"), selection: dateBinding($draft.next), in: (Day.date(draft.start) ?? .distantPast)..., displayedComponents: .date)
                    }
                } header: {
                    Text(LS("扣费周期"))
                } footer: {
                    if draft.extended {
                        Text(LS("赠送或延长的时间到「下次扣费日」为止，之后按原周期（%@）继续计算。", draft.period.name))
                    } else if let s = draft.sub {
                        Text(LS("下次扣费：%@", s.due(onOrAfter: Day.today())))
                    }
                }
                Section {
                    Button { picking = .account } label: {
                        LabeledContent(LS("支出科目"), value: draft.account.isEmpty ? LS("选择") : acctDisplay(draft.account))
                    }
                    .foregroundStyle(.primary)
                    Button { picking = .funding } label: {
                        LabeledContent(LS("付款账户"), value: draft.funding.isEmpty ? LS("选择") : acctDisplay(draft.funding))
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text(LS("用于到期时一键记账，也用于识别已入账的扣费。"))
                }
                if draft.original != nil {
                    Section {
                        Picker(LS("状态"), selection: $draft.status) {
                            ForEach(SubStatus.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                        Button(LS("删除订阅"), role: .destructive) { confirmDelete = true }
                    }
                }
                if let s = draft.sub {
                    Section(LS("将写入")) { MonoText(text: subscriptionText(s)) }
                }
            }
            .keyboardDone()
            .navigationTitle(draft.original != nil ? LS("编辑订阅") : LS("添加订阅"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LS("保存")) { save() }.fontWeight(.semibold).disabled(draft.sub == nil)
                }
            }
            .sheet(item: $picking) { p in
                AccountPicker(title: p == .account ? LS("支出科目") : LS("付款账户"),
                              prefixes: p == .account ? ["Expenses:"] : ["Liabilities:", "Assets:"],
                              current: p == .account ? draft.account : draft.funding) { a in
                    if p == .account { draft.account = a } else { draft.funding = a }
                }
            }
            .confirmationDialog(LS("删除订阅「%@」？", draft.name), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(LS("删除"), role: .destructive) { delete() }
            } message: {
                Text(LS("只删除订阅记录，已入账的扣费交易不受影响。不再续费时也可以把状态改为「已取消」。"))
            }
        }
    }

    private func save() {
        guard let s = draft.sub, let L = store.L else { return }
        let text = subscriptionText(s)
        let label = LS("订阅：%@ %@", s.name, money(s.amount, s.currency))
        // editing, or a directive with the same name already exists: replace it
        if let e = draft.original ?? subscriptions(L).first(where: { $0.name == s.name })?.entry {
            var op = Op(kind: .replace, path: e.file)
            op.old = e.src
            op.text = text
            op.date = s.start
            op.label = label
            dismiss()
            Task { await store.commit([op], word: LS("已更新订阅")) }
            return
        }
        guard let ops = store.makeOps(text, extra: OpExtra(label: label), single: false) else { return }
        dismiss()
        Task { await store.commit(ops, word: LS("已添加订阅")) }
    }

    private func delete() {
        guard let e = draft.original else { return }
        var op = Op(kind: .remove, path: e.file)
        op.old = e.src
        op.date = e.date
        op.label = LS("删除订阅：%@", draft.name)
        dismiss()
        Task { await store.commit([op], word: LS("已删除")) }
    }
}
