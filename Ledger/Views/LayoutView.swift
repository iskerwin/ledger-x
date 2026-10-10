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
    @EnvironmentObject var store: Store
    @State private var c = LedgerXConfig()
    @State private var loaded = false
    @State private var saving = false

    var body: some View {
        let usage = store.L.map(layoutUsage) ?? [:]
        let changed = c != store.effectiveConfig || store.repoConfig == nil
        List {
            Section {
                ForEach(LayoutKind.allCases) { k in kindRow(k, usage[k]) }
            } header: {
                Text(LS("按类型"))
            } footer: {
                Text(LS("留空则自动：写入同类记录最多的文件。可使用 {year}、{month}（交易日期的年、月）和 {root}（开户科目的大类，如 Assets）。新文件第一次写入时会自动在主文件中添加 include。"))
            }

            Section {
                ForEach(c.rules.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Assets:Invest", text: Binding(get: { c.rules.indices.contains(i) ? c.rules[i].account : "" }, set: { if c.rules.indices.contains(i) { c.rules[i].account = $0 } }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("investments/{year}.bean", text: Binding(get: { c.rules.indices.contains(i) ? c.rules[i].file : "" }, set: { if c.rules.indices.contains(i) { c.rules[i].file = $0 } }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .onDelete { c.rules.remove(atOffsets: $0) }
                Button { c.rules.append(LayoutRule(account: "", file: "")) } label: { Label(LS("添加规则"), systemImage: "plus") }
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
                Button {
                    saving = true
                    Task { _ = await store.saveRepoConfig(c); saving = false }
                } label: {
                    HStack { Label(LS("保存到仓库"), systemImage: "square.and.arrow.down"); if saving { Spacer(); ProgressView() } }
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

    private func kindRow(_ k: LayoutKind, _ u: (file: String, count: Int, files: Int)?) -> some View {
        let placeholder: String = {
            switch k {
            case .transactions: return store.journalPattern.trimmed.isEmpty ? store.detectedLayout.journal : store.journalPattern.trimmed
            case .subscriptions: return store.subsFile.trimmed.isEmpty ? "subscriptions.bean" : store.subsFile.trimmed
            default: return u?.file ?? LS("自动")
            }
        }()
        let now: String = {
            guard let u = u else { return LS("暂无记录") }
            return u.files > 1 ? LS("%@ 条，主要在 %@（共 %@ 个文件）", u.count, u.file, u.files) : LS("%@ 条，在 %@", u.count, u.file)
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(k.title)
                Spacer()
                TextField(placeholder, text: Binding(get: { c.files[k.rawValue] ?? "" }, set: { c.files[k.rawValue] = $0 }))
                    .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.callout.monospaced())
            }
            Text(now).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// preview of what moves where, then one commit
struct ReorganizeView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        let moves = store.misplaced
        let groups = Dictionary(grouping: moves) { $0.to }.sorted { $0.key < $1.key }
        List {
            if moves.isEmpty {
                Label(LS("所有记录都已在对应的文件中"), systemImage: "checkmark.seal").foregroundStyle(Color.gain)
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
                    Text(saving ? LS("提交中…") : LS("移动 %@ 条记录（一次提交）", moves.count)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).padding().disabled(saving)
                .background(.bar)
            }
        }
    }
}
