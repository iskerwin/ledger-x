import SwiftUI
import LedgerKit

struct BudgetsDest: Hashable {}

/// a budget's progress bar row
struct BudgetRow: View {
    let p: BudgetProgress
    var body: some View {
        let color: Color = p.over ? .loss : p.ahead ? .warn : .jade
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(acctLabel(p.budget.account)).lineLimit(1)
                if let zh = acctZH(p.budget.account) { Text(zh).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(money(p.spent, p.budget.currency) + " / " + money(p.limit, p.budget.currency, 0))
                    .font(.subheadline.monospacedDigit()).sensitive()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(color.gradient).frame(width: max(4, g.size.width * min(1, p.ratio)))
                    if p.elapsed > 0 && p.elapsed < 1 {
                        Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1.5).offset(x: g.size.width * p.elapsed)
                    }
                }
            }
            .frame(height: 8)
            HStack {
                Text(p.over ? LS("超支 %@", money(-p.remaining, p.budget.currency)) : LS("剩余 %@", money(p.remaining, p.budget.currency)))
                    .foregroundStyle(p.over ? Color.loss : Color.secondary)
                if p.ahead { Text(LS("· 花得比时间快")).foregroundStyle(Color.warn) }
                Spacer()
                Text(String(format: "%.0f%%", p.ratio * 100)).foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
            .sensitive()
        }
        .padding(.vertical, 3)
    }
}

/// 预算: all budgets, their history, add / change / stop
struct BudgetsView: View {
    @EnvironmentObject var store: Store
    @State private var editing: BudgetDraft?
    @AppStorage("ledger.budget.year") private var yearView = false

    var body: some View {
        Group {
            if let L = store.L { list(L) } else { ProgressView() }
        }
        .navigationTitle(LS("预算"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = BudgetDraft(currency: store.L?.base ?? "CNY") } label: { Image(systemName: "plus") }
                    .accessibilityLabel(LS("添加预算"))
            }
        }
        .sheet(item: $editing) { BudgetEditSheet(draft: $0) }
    }

    private func list(_ L: Ledger) -> some View {
        let today = Day.today()
        let key = yearView ? String(today.prefix(4)) : Day.ym(today)
        let progress = budgetProgress(L, key: key)
        let all = budgets(L)
        return List {
            Section {
                Picker(LS("周期"), selection: $yearView) {
                    Text(LS("本月")).tag(false)
                    Text(LS("本年")).tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                if progress.isEmpty { Text(LS("还没有预算。点右上角 + 为支出分类设置每月或每年的额度。")).foregroundStyle(.secondary) }
                ForEach(progress) { p in
                    Button { editing = BudgetDraft(p.budget, today: today) } label: { BudgetRow(p: p) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(LS("停用"), role: .destructive) { stop(p.budget) }
                        }
                }
            } header: {
                Text(yearView ? LS("%@ 年", key) : Day.monthLabel(key))
            } footer: {
                Text(LS("竖线表示时间进度。预算按 Fava 的格式写在账本中：custom \"budget\" 科目 \"monthly\" 金额；日 / 周 / 季 / 年预算会折算到所选周期。"))
            }
            if !all.isEmpty {
                Section(LS("预算记录")) {
                    ForEach(all.reversed()) { b in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(acctLabel(b.account))
                                Text(b.date + " · " + b.period.name).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(b.amount > 0 ? money(b.amount, b.currency) : LS("停用")).monospacedDigit().foregroundStyle(b.amount > 0 ? Color.primary : Color.secondary).sensitive()
                        }
                        .swipeActions {
                            if let e = b.entry {
                                Button(LS("删除"), role: .destructive) { remove(e) }
                            }
                        }
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
    }

    private func stop(_ b: Budget) {
        let date = Day.ym(Day.today()) + "-01"
        let line = budgetLine(date, b.account, b.period, 0, b.currency)
        guard let ops = store.makeOps(line, extra: OpExtra(label: LS("停用预算：%@", b.account)), single: false) else { return }
        Task { await store.commit(ops, word: LS("已停用预算")) }
    }

    private func remove(_ e: Entry) {
        var op = Op(kind: .remove, path: e.file)
        op.old = e.src
        op.date = e.date
        op.label = LS("删除预算：%@ %@", e.values.compactMap { (v: MetaValue) -> String? in if case .raw(let a) = v { return a }; return nil }.first ?? "", e.date)
        Task { await store.commit([op], word: LS("已删除")) }
    }
}

struct BudgetDraft: Identifiable {
    let id = UUID()
    var account = ""
    var period = BudgetPeriod.monthly
    var amount = ""
    var currency = "CNY"
    var date = Day.ym(Day.today()) + "-01"
    var original: Entry?

    init(currency: String) { self.currency = currency }
    init(_ b: Budget, today: String) {
        account = b.account
        period = b.period
        amount = jsNumberString(b.amount)
        currency = b.currency
        // a change starts this month; editing this month's entry replaces it
        date = Day.ym(today) + "-01"
        original = b.date == date ? b.entry : nil
    }
}

struct BudgetEditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var draft: BudgetDraft
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { picking = true } label: {
                        LabeledContent(LS("科目"), value: draft.account.isEmpty ? LS("选择") : acctDisplay(draft.account))
                    }
                    .foregroundStyle(.primary)
                    if let D = store.D {
                        ChipRow {
                            ForEach(D.rankAccounts(["Expenses:"]).map { catOf($0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(10), id: \.self) { a in
                                Chip(label: acctLabel(a), selected: draft.account == a) { draft.account = a }
                            }
                        }
                    }
                    Picker(LS("周期"), selection: $draft.period) {
                        ForEach(BudgetPeriod.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    LabeledContent(LS("金额") + " " + draft.currency) {
                        TextField("2000", text: $draft.amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing).font(.body.monospacedDigit())
                    }
                    DatePicker(LS("生效日期"), selection: dateBinding($draft.date), displayedComponents: .date)
                } footer: {
                    Text(LS("包含所有子科目，例如 Expenses:Food 也统计 Expenses:Food:Drinks。之后的预算记录会替代之前的。"))
                }
                if let a = evalAmount(draft.amount), !draft.account.isEmpty {
                    Section(LS("将写入")) { MonoText(text: budgetLine(draft.date, draft.account, draft.period, a, draft.currency)) }
                }
            }
            .keyboardDone()
            .navigationTitle(draft.original != nil || !draft.account.isEmpty ? LS("编辑预算") : LS("添加预算"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LS("保存")) { save() }.fontWeight(.semibold).disabled(draft.account.isEmpty || evalAmount(draft.amount) == nil)
                }
            }
            .sheet(isPresented: $picking) {
                AccountPicker(title: LS("科目"), prefixes: ["Expenses:", "Income:"], current: draft.account) { draft.account = $0 }
            }
        }
    }

    private func save() {
        guard let a = evalAmount(draft.amount), let L = store.L else { return }
        let line = budgetLine(draft.date, draft.account, draft.period, a, draft.currency)
        let label = LS("预算：%@ %@", draft.account, money(a, draft.currency))
        // same account and date already: replace that line
        if let e = draft.original ?? budgets(L).first(where: { $0.account == draft.account && $0.date == draft.date })?.entry {
            var op = Op(kind: .replace, path: e.file)
            op.old = e.src
            op.text = line
            op.date = draft.date
            op.label = label
            dismiss()
            Task { await store.commit([op], word: LS("已更新预算")) }
            return
        }
        guard let ops = store.makeOps(line, extra: OpExtra(label: label), single: false) else { return }
        dismiss()
        Task { await store.commit(ops, word: LS("已设置预算")) }
    }
}
