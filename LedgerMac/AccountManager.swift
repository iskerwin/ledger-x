import SwiftUI
import LedgerKit

private struct AccountTarget: Identifiable {
    let name: String?
    var id: String { name ?? "" }
}

/// Includes empty, implicit and closed accounts, which the balance page deliberately leaves out.
struct AccountManager: View {
    let ledger: Ledger
    let folder: URL
    @State private var query = ""
    @State private var showClosed = true
    @State private var target: AccountTarget?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("管理账户").font(.headline)
                Spacer()
                Toggle("显示已关闭的账户", isOn: $showClosed).toggleStyle(.checkbox)
                Button("新建账户", systemImage: "plus") { target = AccountTarget(name: nil) }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            TextField("搜索账户", text: $query).textFieldStyle(.roundedBorder).padding([.horizontal, .bottom], 16)
            List {
                ForEach(AccountForm.roots, id: \.self) { root in
                    let accounts = matches(root)
                    if !accounts.isEmpty {
                        Section(["Assets": "资产", "Liabilities": "负债", "Income": "收入", "Expenses": "支出", "Equity": "权益"][root] ?? root) {
                            ForEach(accounts, id: \.name) { account in
                                Button { target = AccountTarget(name: account.name) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(accountTitle(ledger, account.name)).foregroundStyle(.primary)
                                            Text(account.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if account.implicit { Text("未开户").foregroundStyle(Color.warn) }
                                        if account.close.map({ $0 <= Day.today() }) == true { Text("已关闭").foregroundStyle(.secondary) }
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 720, height: 600)
        .sheet(item: $target) { target in
            AccountEditor(ledger: ledger, account: target.name, folder: folder)
        }
    }

    private func matches(_ root: String) -> [Account] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ledger.accounts.values.filter {
            $0.name.hasPrefix(root + ":")
                && (showClosed || ($0.close.map { $0 > Day.today() } ?? true))
                && (text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) || accountTitle(ledger, $0.name).localizedCaseInsensitiveContains(text))
        }.sorted { $0.name < $1.name }
    }

}

private struct AccountEditor: View {
    private enum Change {
        case save(AccountForm, Entry?)
        case close(Entry, String)
        case reopen(Entry)
    }
    let folder: URL
    @State private var original: Entry?
    @State private var closed: Entry?
    let created: Bool
    @State private var baseline: AccountForm
    private let balances: String
    @State private var form: AccountForm
    @State private var closeDate = Day.today()
    @State private var initialCloseDate = Day.today()
    @State private var message = ""
    @State private var saving = false
    @State private var leaving = false
    @State private var closing = false
    @State private var reopening = false
    @State private var review: FolderSave?
    @Environment(\.dismiss) private var dismiss

    init(ledger: Ledger, account: String?, folder: URL) {
        self.folder = folder
        created = account == nil
        _original = State(initialValue: ledger.entries.last { $0.type == .open && $0.account == account })
        _closed = State(initialValue: ledger.entries.last { $0.type == .close && $0.account == account })
        var fields: AccountForm
        if let account, let found = ledger.accounts[account] {
            let first = ledger.txns.first { $0.postings.contains { $0.account == account } }?.date ?? Day.today()
            fields = AccountForm(found, fallbackDate: first)
        } else {
            fields = AccountForm(account: "Assets:", date: Day.today())
            fields.currencies = ledger.base
        }
        _baseline = State(initialValue: fields)
        _form = State(initialValue: fields)
        balances = (ledger.final[account ?? ""] ?? [:]).filter { abs($0.value) > 0.005 }.sorted { $0.key < $1.key }
            .map { money($0.value, $0.key) }.joined(separator: "、")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(created ? "新建账户" : "编辑账户").font(.headline)
                Spacer()
                Button("取消") { close() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("保存") { prepare(.save(form, original)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || (!created && original != nil && form == baseline))
            }
            .padding(16)
            Form {
                Section("开户信息") {
                    if created {
                        TextField("账户", text: $form.account, prompt: Text("Assets:Bank:Example"))
                    } else {
                        LabeledContent("账户", value: form.account).textSelection(.enabled)
                    }
                    DateRow(title: "开立日期", day: $form.date)
                    TextField("显示名称", text: $form.name)
                    TextField("限定币种", text: $form.currencies, prompt: Text("CNY,USD"))
                    Picker("批次方法", selection: $form.booking) {
                        ForEach(AccountForm.bookings, id: \.self) { Text($0.isEmpty ? "默认" : $0).tag($0) }
                    }
                    if form.account.hasPrefix("Assets:") {
                        monthlyDay("核对日", selection: $form.statementDay)
                        Toggle("允许负余额", isOn: $form.allowNegative)
                    } else if form.account.hasPrefix("Liabilities:") {
                        TextField("信用额度", text: $form.limit, prompt: Text("50000 或 50000 CNY"))
                        monthlyDay("账单日", selection: $form.statementDay)
                        monthlyDay("还款日", selection: $form.dueDay)
                    }
                }
                if let original {
                    Section {
                        if let closed {
                            LabeledContent("关闭日期", value: closed.date)
                            Button("重新开启账户", systemImage: "lock.open") { reopening = true }
                        } else {
                            DateRow(title: "关闭日期", day: $closeDate)
                            if !balances.isEmpty {
                                Label("当前余额 " + balances, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(Color.warn)
                            }
                            Button("关闭账户", role: .destructive) { closing = true }
                        }
                    }
                    .disabled(saving || form != baseline)
                    .confirmationDialog("关闭账户？", isPresented: $closing, titleVisibility: .visible) {
                        Button("关闭账户", role: .destructive) { prepare(.close(original, closeDate)) }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将写入一条 close 指令，此后该账户不能再有交易。历史记录保留。")
                    }
                }
                DisclosureGroup("Beancount 原文") {
                    if case .success(let text) = form.directive(keeping: original?.src) {
                        Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(saving)
            ScrollView {
                Text(message).font(.callout).foregroundStyle(Color.loss).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 56)
            .padding(.horizontal, 16)
        }
        .frame(width: 600, height: 640)
        .interactiveDismissDisabled(dirty || saving)
        .confirmationDialog("修改还没有保存", isPresented: $leaving, titleVisibility: .visible) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃修改", role: .destructive) { dismiss() }
        }
        .confirmationDialog("重新开启账户？", isPresented: $reopening, titleVisibility: .visible) {
            Button("重新开启账户") {
                if let closed { prepare(.reopen(closed)) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("重新开启会删除这条 close 指令。") }
        .alert(review?.issues.first?.title ?? "", isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
            if review?.issues.contains(where: \.blocking) == false {
                Button("仍然保存") { if let review { write(review) } }
            }
            Button("返回修改", role: .cancel) {}
        } message: {
            Text(review?.issues.map { [$0.title, $0.detail].filter { !$0.isEmpty }.joined(separator: "\n") }.joined(separator: "\n\n") ?? "")
        }
    }

    private func monthlyDay(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            Text("未设置").tag(0)
            ForEach(1...31, id: \.self) { Text("每月 \($0) 日").tag($0) }
        }
    }

    private func close() {
        if dirty { leaving = true } else { dismiss() }
    }

    private var dirty: Bool { form != baseline || closeDate != initialCloseDate }

    private func prepare(_ change: Change) {
        guard !saving else { return }
        saving = true
        message = ""
        let folder = folder
        Task { @MainActor in
            let result = await Task.detached {
                switch change {
                case .save(let form, let original): return prepareFolderAccount(form, replacing: original, folder: folder)
                case .close(let original, let date): return prepareFolderClose(original, date: date, folder: folder)
                case .reopen(let closed): return prepareFolderDelete(closed, folder: folder)
                }
            }.value
            saving = false
            switch result {
            case .failure(let error): message = error.message
            case .success(let save):
                if save.issues.isEmpty { write(save) } else { review = save }
            }
        }
    }

    private func write(_ save: FolderSave) {
        do {
            try commitFolderSave(save, folder: folder)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
