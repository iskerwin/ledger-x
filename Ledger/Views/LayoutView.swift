import SwiftUI
import LedgerKit

// 仓库结构: where each kind of directive is written, kept in ledger-x.json so every device follows it.

extension Store {
    /// entries that are not where the layout puts them
    var misplaced: [(entry: Entry, to: String)] {
        guard let L = L else { return [] }
        return misplacedEntries(L, layout: layout)
    }

    /// move entries to their files in one commit (with includes for new files)
    func moveOps(_ moves: [(entry: Entry, to: String)]) -> [Op] {
        guard let L = L else { return [] }
        var ops: [Op] = []
        var included = Set<String>()
        for (k, m) in moves.enumerated() {
            let e = m.entry
            if m.to != layout.main && tree?.files[m.to] == nil && !L.files.contains(m.to) && included.insert(m.to).inserted {
                var inc = Op(kind: .include, path: layout.main)
                inc.line = layout.includeLine(m.to)
                inc.silent = true
                ops.append(inc)
            }
            var rm = Op(kind: .remove, path: e.file)
            rm.old = e.src; rm.date = e.date
            if k == 0 { rm.label = LS("按仓库结构整理 %@ 条记录", moves.count) } else { rm.silent = true }
            ops.append(rm)
            var ins = Op(kind: .insert, path: m.to)
            ins.text = trimTrailingSpaces(e.src); ins.date = e.date
            ins.silent = true
            ops.append(ins)
        }
        return ops
    }
}

struct RepoLayoutView: View {
    @Environment(Store.self) var store
    @State private var c = LedgerXConfig()
    @State private var loaded = false
    @State private var saving = false
    @State private var newSlugName = ""
    @State private var newSlug = ""

    /// fill every kind left empty with where it goes now
    private func fillAutomatic(_ usage: [LayoutKind: (file: String, count: Int, files: Int)]) {
        for k in LayoutKind.allCases where (c.files[k.rawValue] ?? "").trimmed.isEmpty {
            if let f = automaticFile(k, usage[k]) { c.files[k.rawValue] = f }
        }
    }

    var body: some View {
        let usage = store.L.map(layoutUsage) ?? [:]
        let changed = c != store.effectiveConfig || store.repoConfig == nil
        List {
            Section {
                LabeledContent(LS("主文件")) {
                    TextField(store.main, text: Binding(get: { c.main ?? "" }, set: { c.main = $0 }))
                        .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.callout.monospaced())
                }
            } footer: {
                Text(LS("账本从这个文件开始读（include 其他文件）。留空为 main.bean。"))
            }
            Section {
                ForEach(LayoutKind.allCases) { k in kindRow(k, usage[k]) }
                if LayoutKind.allCases.contains(where: { (c.files[$0.rawValue] ?? "").trimmed.isEmpty }) {
                    Button { fillAutomatic(usage) } label: { Label(LS("把自动规则写成固定规则"), systemImage: "text.badge.checkmark").labelStyle(ControlLabelStyle()) }
                }
            } header: {
                Text(LS("按类型"))
            } footer: {
                Text(LS("留空则自动：写入同类记录最多的文件。可使用 {year}、{month}（交易日期的年、月）、{root}（开户科目的大类，如 Assets）和 {root_lower}（小写，如 assets）。新文件第一次写入时会自动在主文件中添加 include。「写成固定规则」把现在的自动结果填进来，保存后 ledger-x.json 里就有完整的规则。"))
            }

            Section {
                ForEach(c.rules.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: AppSpacing.icon) {
                        TextField("Assets:Invest", text: Binding(get: { c.rules.indices.contains(i) ? c.rules[i].account : "" }, set: { if c.rules.indices.contains(i) { c.rules[i].account = $0 } }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("investments/{year}.bean", text: Binding(get: { c.rules.indices.contains(i) ? c.rules[i].file : "" }, set: { if c.rules.indices.contains(i) { c.rules[i].file = $0 } }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .onDelete { c.rules.remove(atOffsets: $0) }
                Button { c.rules.append(LayoutRule(account: "", file: "")) } label: { Label(LS("添加规则"), systemImage: "plus").labelStyle(ControlLabelStyle()) }
            } header: {
                Text(LS("按科目分流（交易）"))
            } footer: {
                Text(LS("交易中任一分录的科目属于该科目（含子科目）时写入对应文件，按顺序匹配第一条；不匹配的交易写入上面的「交易」文件。"))
            }

            Section(LS("报销")) {
                LabeledContent(LS("报销应收科目")) {
                    TextField("Assets:Receivable:Reimbursement", text: Binding(get: { c.receivable ?? "" }, set: { c.receivable = $0 }))
                        .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }

            Section {
                ForEach(c.slugs.keys.sorted(), id: \.self) { k in
                    LabeledContent(k) {
                        TextField("pinyin", text: Binding(get: { c.slugs[k] ?? "" }, set: { c.slugs[k] = $0 }))
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.callout.monospaced())
                    }
                }
                .onDelete { idx in let ks = c.slugs.keys.sorted(); for i in idx { c.slugs[ks[i]] = nil } }
                HStack(spacing: AppSpacing.control) {
                    TextField(LS("收付款方名称"), text: $newSlugName)
                    TextField("pinyin", text: $newSlug).textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout.monospaced())
                    Button { c.slugs[newSlugName.trimmed] = newSlug.trimmed; newSlugName = ""; newSlug = "" } label: { Label(LS("添加"), systemImage: "plus").labelStyle(ControlLabelStyle()) }
                        .disabled(newSlugName.trimmed.isEmpty || newSlug.trimmed.isEmpty)
                }
            } header: {
                Text(LS("收付款方拼音"))
            } footer: {
                HintFooter(LS("生成 ^refund-、^reimburse- 这类链接时，收付款方名称转成拼音；读音不对的在这里指定，如「岭南通 羊城通」→ yangchengtong。"), tip: LS("左滑可删除。"), .swipe)
            }

            // the rest of ledger-x.json, changed where it is used
            Section {
                NavigationLink { NetWorthSettingsView() } label: {
                    LabeledContent(LS("统计范围"), value: Set((c.netWorthExclude ?? []) + (c.balanceExclude ?? [])).isEmpty ? LS("全部计入") : LS("已排除 %@ 个", Set((c.netWorthExclude ?? []) + (c.balanceExclude ?? [])).count))
                }
                LabeledContent(LS("默认付款账户"), value: c.defaultFunding.map { store.displayName($0) ?? acctLabel($0) } ?? LS("自动"))
                LabeledContent(LS("默认币种"), value: c.defaultCurrency ?? LS("跟随付款账户"))
                LabeledContent(LS("大额支出"), value: (c.largeExpense ?? 2000) == 0 ? LS("不提醒") : money(c.largeExpense ?? 2000, "CNY", 0))
                LabeledContent(LS("工资条模板"), value: LS("%@ 个", (c.payslips ?? []).count))
                LabeledContent(LS("已核对 / 已忽略"), value: LS("%@ 项", (c.alertsConfirmed ?? []).count + (c.linksIgnored ?? []).count + (c.subsIgnored ?? []).count))
                LabeledContent(LS("常用交易置顶 / 隐藏"), value: LS("%@ 项", (c.templatesPinned ?? []).count + (c.templatesHidden ?? []).count))
            } header: {
                Text(LS("其他共用设置"))
            } footer: {
                Text(LS("这些也在 %@ 里，在用到的地方修改：记账偏好在设置，大额支出在「值得留意」，工资条模板在「报表 → 工资」，常用交易在记一笔。", LedgerXConfig.path))
            }

            Section {
                Button {
                    saving = true
                    Task { _ = await store.saveRepoConfig(c); saving = false }
                } label: {
                    HStack(spacing: AppSpacing.control) { Label(LS("保存到仓库"), systemImage: "square.and.arrow.down").labelStyle(ControlLabelStyle()); if saving { Spacer(); ProgressView() } }
                }
                .disabled(!changed || saving)
                NavigationLink { ReorganizeView() } label: {
                    LabeledContent(LS("按规则整理已有记录"), value: store.repoConfig == nil ? "" : LS("%@ 条", store.misplaced.count))
                }
                .disabled(store.repoConfig == nil)
            } footer: {
                Text(store.repoConfig == nil
                     ? LS("设置保存在仓库根目录的 %@ 中，换手机或多台设备共用同一套规则。目前仓库中还没有这个文件，保存后才会生效。", LedgerXConfig.path)
                     : LS("设置保存在仓库根目录的 %@ 中，换手机或多台设备共用同一套规则。修改后需保存才会生效；整理按已保存的规则进行。", LedgerXConfig.path))
            }
        }
        .navigationTitle(LS("仓库结构"))
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDone()
        .onAppear { if !loaded { c = store.effectiveConfig; loaded = true } }
    }

    /// where a kind goes when it isn't set, as a file or pattern that would do the same if written down; nil when
    /// one pattern can't say it (open / close spread over files that don't follow the root's name)
    private func automaticFile(_ k: LayoutKind, _ u: (file: String, count: Int, files: Int)?) -> String? {
        let journal = store.journalPattern.trimmed.isEmpty ? store.detectedLayout.journal : store.journalPattern.trimmed
        switch k {
        case .transactions: return journal
        case .subscriptions: return store.subsFile.trimmed.isEmpty ? "subscriptions.bean" : store.subsFile.trimmed
        case .budget: return u?.file ?? store.main
        case .accounts:
            // open / close go to the file already holding most of that root's accounts
            guard let L = store.L else { return nil }
            var by: [String: [String: Int]] = [:]
            for e in L.entries where (e.type == .open || e.type == .close) && !e.file.isEmpty {
                let r = (e.account ?? "").components(separatedBy: ":")[0]
                by[r, default: [:]][e.file, default: 0] += 1
            }
            let top = by.compactMapValues { m in m.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key }
            let files = Set(top.values)
            if files.count <= 1 { return files.first }
            // accounts/assets.bean, accounts/expenses.bean … → accounts/{root_lower}.bean
            for (token, f) in [("{root_lower}", { (r: String) in r.lowercased() }), ("{root}", { (r: String) in r })] {
                let patterns = Set(top.map { r, file in file.replacingOccurrences(of: f(r), with: token) })
                if patterns.count == 1, let p = patterns.first, p.contains(token) { return p }
            }
            return nil
        default: return u?.file ?? journal
        }
    }

    /// the same in words, for a kind left empty
    private func automatic(_ k: LayoutKind, _ u: (file: String, count: Int, files: Int)?) -> String {
        automaticFile(k, u) ?? LS("按科目大类，各自原来的文件")
    }

    private func kindRow(_ k: LayoutKind, _ u: (file: String, count: Int, files: Int)?) -> some View {
        let auto = automatic(k, u)
        let set = !(c.files[k.rawValue] ?? "").trimmed.isEmpty
        let now: String = {
            guard let u = u else { return LS("暂无记录") }
            return u.files > 1 ? LS("%@ 条，主要在 %@（共 %@ 个文件）", u.count, u.file, u.files) : LS("%@ 条，在 %@", u.count, u.file)
        }()
        return VStack(alignment: .leading, spacing: AppSpacing.detail) {
            HStack(spacing: AppSpacing.control) {
                Text(k.title)
                Spacer()
                TextField(LS("自动"), text: Binding(get: { c.files[k.rawValue] ?? "" }, set: { c.files[k.rawValue] = $0 }))
                    .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.callout.monospaced())
            }
            // what happens when it is left empty, spelled out (a placeholder alone was easy to miss)
            if !set {
                Label(LS("未设置，自动写入 %@", auto), systemImage: "wand.and.stars").labelStyle(ControlLabelStyle()).font(.caption).foregroundStyle(Color.jadeInk).lineLimit(2)
            }
            Text(now).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// preview of what moves where, then one commit
struct ReorganizeView: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        let moves = store.misplaced
        let groups = Dictionary(grouping: moves) { $0.to }.sorted { $0.key < $1.key }
        List {
            if moves.isEmpty {
                Label(LS("所有记录都已在对应的文件中"), systemImage: "checkmark.seal").labelStyle(ControlLabelStyle()).foregroundStyle(Color.gain)
            }
            ForEach(groups, id: \.key) { g in
                Section {
                    let from = Dictionary(grouping: g.value) { $0.entry.file }.sorted { $0.key < $1.key }
                    ForEach(from, id: \.key) { f in
                        LabeledContent(f.key, value: LS("%@ 条", f.value.count)).font(.subheadline)
                    }
                    ForEach(Array(g.value.prefix(5).enumerated()), id: \.offset) { _, m in
                        Text(m.entry.src.components(separatedBy: "\n").first ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if g.value.count > 5 { Text(LS("等 %@ 条", g.value.count)).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text("→ " + g.key).textCase(nil)
                }
            }
        }
        .navigationTitle(LS("按规则整理"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !moves.isEmpty {
                Button {
                    saving = true
                    Task {
                        _ = await store.commit(store.moveOps(moves), word: LS("已整理 %@ 条记录", moves.count), closing: { dismiss() })
                        saving = false
                    }
                } label: {
                    Label(saving ? LS("提交中…") : LS("移动 %@ 条记录（一次提交）", moves.count), systemImage: "folder").labelStyle(ControlLabelStyle()).frame(maxWidth: .infinity)
                }
                .primaryButton().padding(AppSpacing.content).disabled(saving)
                .background(.bar)
            }
        }
    }
}
