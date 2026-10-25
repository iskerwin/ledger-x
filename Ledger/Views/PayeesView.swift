import SwiftUI
import LedgerKit

struct PayeesDest: Hashable {}
struct PayeeDest: Hashable { let name: String }

/// one payee across the ledger
struct PayeeSummary: Identifiable {
    let name: String
    var n = 0
    var last = ""
    /// your spending with them (base currency)
    var spent = 0.0
    /// income from them (base currency)
    var received = 0.0
    var id: String { name }
}

/// every payee on a transaction header, most used first
func payeeSummaries(_ L: Ledger) -> [PayeeSummary] {
    var by: [String: PayeeSummary] = [:]
    for t in L.txns where !t.synthetic && !t.payee.isEmpty {
        var s = by[t.payee] ?? PayeeSummary(name: t.payee)
        s.n += 1
        if t.date > s.last { s.last = t.date }
        let c = classify(t, L)
        switch c.kind {
        case .expense, .refund: s.spent -= c.amount
        case .income: s.received += c.amount
        default: break
        }
        by[t.payee] = s
    }
    return by.values.sorted { $0.n != $1.n ? $0.n > $1.n : $0.name < $1.name }
}

/// 收付款方: search, check how often each one is used, rename or merge them
struct PayeesView: View {
    @Environment(Store.self) var store
    @State private var q = ""
    @State private var selecting = false
    @State private var picked: Set<String> = []
    @State private var renaming: PayeeRename?

    var body: some View {
        Group {
            if let L = store.L { list(L) } else { PageLoading() }
        }
        .refreshable { await store.refresh() }
        .navigationTitle(LS("收付款方"))
        .navigationBarTitleDisplayMode(.inline)
        .appSearchable(text: $q, prompt: LS("搜索收付款方"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation(AppMotion.standard) { selecting.toggle(); picked = [] } } label: { Label(selecting ? LS("完成") : LS("选择"), systemImage: selecting ? "checkmark" : "checkmark.circle").labelStyle(ControlLabelStyle()) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack(spacing: AppSpacing.control) {
                    Text(LS("已选 %@ 个", picked.count)).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button { renaming = PayeeRename(names: Array(picked)) } label: {
                        Label(picked.count > 1 ? LS("合并…") : LS("重命名…"), systemImage: "arrow.triangle.merge").labelStyle(ControlLabelStyle()).font(.subheadline.weight(.semibold))
                    }
                    .disabled(picked.isEmpty)
                }
                .padding(.horizontal, AppSpacing.content).padding(.vertical, AppSpacing.control)
                .background(.regularMaterial, in: Capsule())
                .padding(.horizontal, AppSpacing.control).padding(.bottom, AppSpacing.detail)
            }
        }
        .sheet(item: $renaming) { PayeeRenameSheet(target: $0) { selecting = false; picked = [] } }
    }

    private func list(_ L: Ledger) -> some View {
        let all = payeeSummaries(L)
        let t = q.trimmed.lowercased()
        let rows = t.isEmpty ? all : all.filter { $0.name.lowercased().contains(t) }
        return List {
            Section {
                ForEach(rows) { p in
                    if selecting {
                        Button {
                            if picked.contains(p.name) { picked.remove(p.name) } else { picked.insert(p.name) }
                        } label: {
                            HStack(spacing: AppSpacing.icon) {
                                Image(systemName: picked.contains(p.name) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(picked.contains(p.name) ? Color.jade : Color.secondary)
                                PayeeRow(p: p)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(picked.contains(p.name) ? .isSelected : [])
                    } else {
                        NavigationLink(value: PayeeDest(name: p.name)) { PayeeRow(p: p) }
                    }
                }
            } header: {
                Text(LS("%@ 个", rows.count))
            } footer: {
                Text(LS("重命名会把账本里所有这个收付款方的交易改成新名字（只改交易第一行引号里的名称），订阅里的 payee、工资模板的公司名一并修改。改成一个已有的名字就是合并。可以撤回。"))
            }
        }
    }
}

struct PayeeRow: View {
    let p: PayeeSummary
    var body: some View {
        HStack(spacing: AppSpacing.control) {
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                Text(p.name).lineLimit(1)
                Text(LS("%@ 笔 · 最近 %@", p.n, p.last)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: AppSpacing.detail) {
                if p.spent > 0.005 { Text(money(p.spent)).font(.subheadline).monospacedDigit().sensitive() }
                if p.received > 0.005 { Text("+" + money(p.received)).font(.caption).monospacedDigit().foregroundStyle(Color.gain).sensitive() }
            }
        }
    }
}

/// one payee: totals, rename, and every transaction with them
struct PayeeDetailView: View {
    @Environment(Store.self) var store
    let name: String
    @State private var renaming: PayeeRename?
    @State private var limit = 100

    var body: some View {
        List {
            if let L = store.L {
                let ts = L.txns.filter { $0.payee == name && !$0.synthetic }.reversed()
                if let p = payeeSummaries(L).first(where: { $0.name == name }) {
                    Section {
                        LabeledContent(LS("交易"), value: LS("%@ 笔", p.n))
                        if p.spent > 0.005 { LabeledContent(LS("支出")) { Amount(n: p.spent) } }
                        if p.received > 0.005 { LabeledContent(LS("收入")) { Amount(n: p.received) } }
                        LabeledContent(LS("最近"), value: p.last)
                        Button { renaming = PayeeRename(names: [name]) } label: { Label(LS("重命名或合并…"), systemImage: "pencil").labelStyle(ControlLabelStyle()) }
                    }
                    Section(LS("交易")) {
                        ForEach(Array(ts.prefix(limit)), id: \.id) { t in NavigationLink(value: TxDest(t)) { TxRow(t: t, showDate: true) } }
                        if ts.count > limit { Button { limit += 200 } label: { Label(LS("显示更多"), systemImage: "chevron.down").labelStyle(ControlLabelStyle()) } }
                    }
                } else {
                    Text(LS("账本里已没有「%@」", name)).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $renaming) { PayeeRenameSheet(target: $0) {} }
    }
}

struct PayeeRename: Identifiable {
    let id = UUID()
    let names: [String]
}

/// rename one payee, or merge several into one name (new or existing): one commit over every file
struct PayeeRenameSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let target: PayeeRename
    var done: () -> Void
    @State private var to = ""
    @State private var counts: [String: Int] = [:]   // file → lines to change
    @State private var saving = false
    @State private var ready = false

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L { form(L) } else { PageLoading() }
            }
            .navigationTitle(target.names.count > 1 ? LS("合并收付款方") : LS("重命名收付款方"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } } }
            .task { await count() }
        }
    }

    private var newName: String { to.trimmed }

    private func form(_ L: Ledger) -> some View {
        let all = payeeSummaries(L)
        let mine = all.filter { target.names.contains($0.name) }
        let existing = all.first { $0.name == newName && !target.names.contains(newName) }
        let lines = counts.values.reduce(0, +)
        let cfg = store.repoConfig
        let payslip = cfg?.payslips?.contains { target.names.contains($0.employer) } ?? false
        let slug = cfg?.slugs.keys.contains { target.names.contains($0) } ?? false
        return Form {
            Section {
                ForEach(mine) { PayeeRow(p: $0) }
            } header: {
                Text(LS("要改的"))
            }
            Section {
                TextField(LS("新名称"), text: $to)
                if target.names.count > 1 {
                    ChipRow { ForEach(mine) { p in Chip(label: p.name, selected: newName == p.name) { to = p.name } } }
                }
            } header: {
                Text(LS("改成"))
            } footer: {
                if let e = existing { Text(LS("「%@」已有 %@ 笔，将合并在一起。", e.name, e.n)) }
            }
            Section(LS("将修改")) {
                Text(LS("%@ 处，分布在 %@ 个文件（交易第一行和订阅的 payee）", lines, counts.count)).font(.footnote)
                if payslip { Text(LS("工资模板的公司名一并改为新名称；已有的 ^salary- 链接不变。")).font(.footnote) }
                if slug { Text(LS("ledger-x.json 中这个名称的拼音设置随之改名。")).font(.footnote) }
                Text(LS("已有的链接名（如 ^refund-…）不改；「值得留意」里已核对的提示可能会重新出现。")).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: AppSpacing.control) { Spacer(); BusyLabel(busy: saving, title: target.names.count > 1 ? LS("合并") : LS("重命名"), systemImage: target.names.count > 1 ? "arrow.triangle.merge" : "pencil").fontWeight(.semibold); Spacer() }
                }
                .primaryButton()
                .disabled(newName.isEmpty || (target.names == [newName]) || lines == 0 || saving)
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            // merging: the most used name by default
            if target.names.count > 1 { to = mine.first?.name ?? "" } else { to = target.names.first ?? "" }
        }
    }

    /// how many lines each file would change
    private func count() async {
        guard let L = store.L else { return }
        var c: [String: Int] = [:]
        for f in L.files {
            guard let t = try? await store.fileText(f) else { continue }
            let n = target.names.reduce(0) { $0 + countPayee(t, $1) }
            if n > 0 { c[f] = n }
        }
        counts = c
    }

    private func save() async {
        let to = newName
        guard !to.isEmpty else { return }
        saving = true
        defer { saving = false }
        var ops: [Op] = []
        let label = target.names.count > 1 ? LS("合并收付款方：%@ → %@", target.names.joined(separator: LS("、")), to) : LS("重命名收付款方：%@ → %@", target.names[0], to)
        for f in counts.keys.sorted() {
            for n in target.names where n != to {
                var op = Op(kind: .renamePayee, path: f)
                op.old = n
                op.text = to
                op.silent = !ops.isEmpty
                if ops.isEmpty { op.label = label; op.summary = label }
                ops.append(op)
            }
        }
        // the salary templates and payee spellings that use the old names
        if var c = store.repoConfig {
            var changed = false
            if var ps = c.payslips {
                for i in ps.indices where target.names.contains(ps[i].employer) && ps[i].employer != to {
                    // keep the link part the salary links already use
                    if (ps[i].slug ?? "").trimmed.isEmpty { ps[i].slug = ps[i].linkSlug }
                    ps[i].employer = to
                    changed = true
                }
                c.payslips = ps
            }
            for n in target.names where n != to {
                if let s = c.slugs[n] {
                    c.slugs[n] = nil
                    if c.slugs[to] == nil { c.slugs[to] = s }
                    changed = true
                }
            }
            if changed {
                var op = await store.fileWriteOp(LedgerXConfig.path, text: c.json())
                op.silent = true
                ops.append(op)
            }
        }
        guard !ops.isEmpty else { return }
        if await store.commit(ops, word: target.names.count > 1 ? LS("已合并") : LS("已重命名"), closing: { dismiss() }) {
            done()
            store.popToken += 1
        }
    }
}
