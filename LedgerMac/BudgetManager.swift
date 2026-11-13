import SwiftUI
import LedgerKit

private enum BudgetAction {
    case save(BudgetForm, replacing: Entry?, previous: Entry?)
    case delete(Entry)

    func prepare(in folder: URL) -> Result<FolderSave, FolderSaveError> {
        switch self {
        case .save(let form, let replacing, let previous): return prepareFolderBudget(form, replacing: replacing, previous: previous, folder: folder)
        case .delete(let entry): return prepareFolderDelete(entry, folder: folder)
        }
    }
}

private struct BudgetTarget: Identifiable {
    let id = UUID()
    var budget: Budget? = nil
}

struct BudgetManager: View {
    let ledger: Ledger
    let folder: URL
    @State private var history = false
    @State private var editing: BudgetTarget?
    @State private var stopping: Budget?
    @State private var deleting: Budget?
    @State private var busy = false
    @State private var message = ""
    @State private var review: FolderSave?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let records = history ? Array(budgets(ledger).reversed()) : activeBudgets(ledger, at: Day.today())
        VStack(spacing: 0) {
            HStack {
                Text("管理预算").font(.headline)
                Spacer()
                Button("添加预算", systemImage: "plus") { editing = BudgetTarget() }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Picker("预算记录", selection: $history) {
                Text("当前预算").tag(false)
                Text("历史记录").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            if records.isEmpty {
                ContentUnavailableView("没有预算", systemImage: "chart.pie")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(records) { budget in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(accountTitle(ledger, budget.account))
                            Text(budget.date + " · " + budget.period.name).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(money(budget.amount, budget.currency)).monospacedDigit()
                        Menu {
                            if !history {
                                Button("编辑预算") { editing = BudgetTarget(budget: budget) }
                                Button("停用", role: .destructive) { stopping = budget }
                            }
                            if history { Button("删除记录", role: .destructive) { deleting = budget } }
                        } label: { Image(systemName: "ellipsis") }
                        .menuIndicator(.hidden)
                        .accessibilityLabel("预算操作")
                    }
                    .padding(.vertical, 4)
                }
            }
            ScrollView { Text(message).font(.callout).foregroundStyle(Color.loss).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 48).padding(.horizontal, 16)
        }
        .frame(width: 680, height: 560)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .sheet(item: $editing) { target in BudgetEditor(ledger: ledger, budget: target.budget, folder: folder) }
        .confirmationDialog("停用预算？", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }), presenting: stopping) { budget in
            Button("停用", role: .destructive) { stop(budget) }
            Button("取消", role: .cancel) {}
        } message: { _ in Text("从本月起写入零预算，之前的记录保留。") }
        .confirmationDialog("删除这条预算记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { budget in
            Button("删除记录", role: .destructive) { if let entry = budget.entry { remove(entry) } }
            Button("取消", role: .cancel) {}
        } message: { _ in Text("删除后，更早的预算可能重新生效。") }
        .alert(review?.issues.first?.title ?? "", isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
            if review?.issues.contains(where: \.blocking) == false { Button("仍然保存") { if let review { write(review) } } }
            Button("返回修改", role: .cancel) {}
        } message: { Text(review?.issues.map { $0.title + "\n" + $0.detail }.joined(separator: "\n\n") ?? "") }
    }

    private func stop(_ budget: Budget) {
        var form = BudgetForm(budget)
        form.amount = "0"
        let original = budgets(ledger).first { $0.account == form.account && $0.date == form.date }?.entry
        prepare(.save(form, replacing: original, previous: budget.entry))
    }

    private func remove(_ entry: Entry) {
        prepare(.delete(entry))
    }

    private func prepare(_ action: BudgetAction) {
        guard !busy else { return }
        busy = true
        message = ""
        let folder = folder
        Task { @MainActor in
            let result = await Task.detached { action.prepare(in: folder) }.value
            busy = false
            switch result {
            case .failure(let error): message = error.message
            case .success(let save): if save.issues.isEmpty { write(save) } else { review = save }
            }
        }
    }

    private func write(_ save: FolderSave) {
        do { try commitFolderSave(save, folder: folder) } catch { message = error.localizedDescription }
    }
}

private struct BudgetEditor: View {
    let folder: URL
    let previous: Entry?
    private let baseline: BudgetForm
    @State private var records: [Budget]
    private let accounts: [String]
    @State private var form: BudgetForm
    @State private var busy = false
    @State private var message = ""
    @State private var leaving = false
    @State private var replacing = false
    @State private var review: FolderSave?
    @Environment(\.dismiss) private var dismiss

    init(ledger: Ledger, budget: Budget?, folder: URL) {
        self.folder = folder
        previous = budget?.entry
        _records = State(initialValue: budgets(ledger))
        let fields = budget.map { BudgetForm($0) } ?? BudgetForm(currency: ledger.base)
        baseline = fields
        _form = State(initialValue: fields)
        var choices = Set<String>()
        for name in ledger.accounts.keys where name.hasPrefix("Expenses:") || name.hasPrefix("Income:") {
            let parts = name.components(separatedBy: ":")
            for end in 2...parts.count { choices.insert(parts.prefix(end).joined(separator: ":")) }
        }
        if !fields.account.isEmpty { choices.insert(fields.account) }
        accounts = choices.sorted()
    }

    private var original: Entry? { records.first { $0.account == form.account && $0.date == form.date }?.entry }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(previous == nil ? "添加预算" : "编辑预算").font(.headline)
                Spacer()
                Button("取消") { if form == baseline { dismiss() } else { leaving = true } }
                    .keyboardShortcut(.cancelAction).disabled(busy)
                Button("保存") {
                    if let original, original !== previous { replacing = true } else { prepare() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || form.account.isEmpty || evalAmount(form.amount) == nil)
            }
            .padding(16)
            Form {
                Section {
                    if previous != nil {
                        LabeledContent("科目", value: acctDisplay(form.account))
                    } else {
                        Picker("科目", selection: $form.account) {
                            Text("选择科目").tag("")
                            ForEach(accounts, id: \.self) { Text(acctDisplay($0)).tag($0) }
                        }
                    }
                    Picker("周期", selection: $form.period) {
                        ForEach(BudgetPeriod.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    TextField("金额", text: $form.amount, prompt: Text("2000.00")).monospacedDigit()
                    TextField("币种", text: $form.currency)
                    DateRow(title: "生效日期", day: $form.date)
                }
                DisclosureGroup("将写入") {
                    if case .success(let text) = form.directive(keeping: original?.src) {
                        Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(busy)
            ScrollView { Text(message).font(.callout).foregroundStyle(Color.loss).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 56).padding(.horizontal, 16)
        }
        .frame(width: 560, height: 480)
        .interactiveDismissDisabled(busy || form != baseline)
        .confirmationDialog("还有未保存的修改", isPresented: $leaving, titleVisibility: .visible) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃修改", role: .destructive) { dismiss() }
        }
        .confirmationDialog("替换这一天的预算？", isPresented: $replacing, titleVisibility: .visible) {
            Button("保存") { prepare() }
            Button("取消", role: .cancel) {}
        }
        .alert(review?.issues.first?.title ?? "", isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
            if review?.issues.contains(where: \.blocking) == false { Button("仍然保存") { if let review { write(review) } } }
            Button("返回修改", role: .cancel) {}
        } message: { Text(review?.issues.map { $0.title + "\n" + $0.detail }.joined(separator: "\n\n") ?? "") }
    }

    private func prepare() {
        guard !busy else { return }
        busy = true
        message = ""
        let action = BudgetAction.save(form, replacing: original, previous: previous), folder = folder
        Task { @MainActor in
            let result = await Task.detached { action.prepare(in: folder) }.value
            busy = false
            switch result {
            case .failure(let error): message = error.message
            case .success(let save): if save.issues.isEmpty { write(save) } else { review = save }
            }
        }
    }

    private func write(_ save: FolderSave) {
        do { try commitFolderSave(save, folder: folder); dismiss() } catch { message = error.localizedDescription }
    }
}
