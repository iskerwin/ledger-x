import SwiftUI
import UniformTypeIdentifiers
import LedgerKit

/// one bill line and what it will become
struct ImportItem: Identifiable {
    var id: Int { row.id }
    var row: ImportRow
    var include: Bool
    var account: String
    var funding: String
    var duplicate: Entry?
    /// set by hand (not overwritten when a similar row changes)
    var manual = false
}

/// 导入账单: Alipay / WeChat / bank exports → transactions
struct ImportView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var fileName = ""
    @State private var data: Data?
    @State private var table: ImportTable?
    @State private var items: [ImportItem] = []
    @State private var source = ImportSource.alipay
    @State private var defaultFunding = ""
    @State private var keepOrder = true
    @State private var filter = 0     // 0 all, 1 selected, 2 needs account, 3 duplicates
    @State private var pickAccount: Int?
    @State private var pickFunding: Int?
    @State private var pickDefault = false
    @State private var showColumns = false

    /// payment method → account, remembered per source
    @AppStorage("ledger.import.methods") private var methodMapData = Data()

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L, let D = store.D {
                    if table == nil { start } else { list(L, D) }
                } else { ProgressView() }
            }
            .navigationTitle(LS("导入账单"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                if table != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(LS("导入 %@ 笔", selected.count)) { save() }
                            .fontWeight(.semibold)
                            .disabled(selected.isEmpty || selected.contains { $0.account.isEmpty || $0.funding.isEmpty })
                    }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: Self.types) { result in
                guard case .success(let url) = result else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                guard let d = try? Data(contentsOf: url) else { store.show(LS("无法读取文件")); return }
                load(d, name: url.lastPathComponent)
            }
            .sheet(item: Binding(get: { pickAccount.map { IntBox(v: $0) } }, set: { pickAccount = $0?.v })) { b in
                let it = items.first { $0.id == b.v }
                AccountPicker(title: LS("科目"), prefixes: it?.row.direction == .income ? ["Income:", "Assets:", "Liabilities:"] : ["Expenses:", "Assets:", "Liabilities:", "Income:"],
                              current: it?.account ?? "", allowAny: true) { setAccount(b.v, $0) }
            }
            .sheet(item: Binding(get: { pickFunding.map { IntBox(v: $0) } }, set: { pickFunding = $0?.v })) { b in
                AccountPicker(title: LS("付款账户"), prefixes: ["Assets:", "Liabilities:"], current: items.first { $0.id == b.v }?.funding ?? "", allowAny: true) { setFunding(b.v, $0) }
            }
            .sheet(isPresented: $pickDefault) {
                AccountPicker(title: LS("默认账户"), prefixes: ["Assets:", "Liabilities:"], current: defaultFunding, allowAny: true) { a in
                    defaultFunding = a
                    for i in items.indices where items[i].funding.isEmpty { items[i].funding = a }
                    recheckDuplicates()
                }
            }
            .task {
                if let p = store.demoEnv["LEDGER_IMPORT"], let d = try? Data(contentsOf: URL(fileURLWithPath: p)) { load(d, name: (p as NSString).lastPathComponent) }
            }
        }
    }

    static let types: [UTType] = [.commaSeparatedText, .plainText, .text, UTType(filenameExtension: "xlsx") ?? .data, UTType(filenameExtension: "xls") ?? .data, .data]

    private var start: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    IconBadge(symbol: "square.and.arrow.down.on.square", color: .jade, size: 44)
                    Text(LS("从支付宝、微信或银行导出账单文件，选择后会逐笔匹配科目与付款账户，并标出账本里已有的交易。")).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                Button { picking = true } label: { Label(LS("选择账单文件"), systemImage: "doc.badge.plus") }
            }
            Section(LS("如何导出")) {
                help(LS("支付宝"), LS("我的 → 账单 → 右上角 … → 开具交易流水证明 → 用于个人对账，选择时间范围，发送到邮箱；解压后得到 CSV。"))
                help(LS("微信"), LS("我 → 服务 → 钱包 → 账单 → 常见问题 → 下载账单 → 用于个人对账，发送到邮箱；解压后得到 xlsx。"))
                help(LS("银行"), LS("网银或 App 中导出交易明细为 CSV / Excel(xlsx)。导入后可手动指定日期、金额、对方等列。"))
            }
        }
    }

    private func help(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: loading

    private var methodMap: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: methodMapData)) ?? [:] }
        nonmutating set { methodMapData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    private func load(_ d: Data, name: String, columns: ImportColumns? = nil) {
        guard let t = readBill(d, fileName: name, columns: columns) else { store.show(LS("无法识别该文件")); return }
        data = d
        fileName = name
        if columns == nil { source = t.source }
        table = t
        build(t)
    }

    private func build(_ t: ImportTable) {
        guard let L = store.L, let D = store.D else { return }
        let map = methodMap
        items = t.rows.map { r in
            let fund = map[source.rawValue + "|" + r.method] ?? guessFunding(r.method, source: source, L, D) ?? defaultFunding
            let acct = guessCategory(r, L, D) ?? ""
            let dup = findDuplicate(r, funding: fund.isEmpty ? nil : fund, L)
            return ImportItem(row: r, include: dup == nil && r.direction != .neutral, account: acct, funding: fund, duplicate: dup)
        }.sorted { $0.row.date != $1.row.date ? $0.row.date > $1.row.date : $0.row.time > $1.row.time }
    }

    private func recheckDuplicates() {
        guard let L = store.L else { return }
        for i in items.indices {
            let d = findDuplicate(items[i].row, funding: items[i].funding.isEmpty ? nil : items[i].funding, L)
            if (d == nil) != (items[i].duplicate == nil) { items[i].include = d == nil && items[i].row.direction != .neutral }
            items[i].duplicate = d
        }
    }

    private func setAccount(_ id: Int, _ a: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].account = a
        items[i].manual = true
        // same payee, not chosen by hand yet: same account
        let payee = items[i].row.payee
        for k in items.indices where k != i && !items[k].manual && items[k].row.payee == payee && items[k].row.direction == items[i].row.direction {
            items[k].account = a
        }
    }

    private func setFunding(_ id: Int, _ a: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let m = items[i].row.method
        for k in items.indices where items[k].row.method == m { items[k].funding = a }
        if !m.isEmpty { var map = methodMap; map[source.rawValue + "|" + m] = a; methodMap = map }
        recheckDuplicates()
    }

    private var selected: [ImportItem] { items.filter { $0.include } }

    // MARK: list

    private func list(_ L: Ledger, _ D: Derived) -> some View {
        let shown = items.filter {
            switch filter {
            case 1: return $0.include
            case 2: return $0.account.isEmpty || $0.funding.isEmpty
            case 3: return $0.duplicate != nil
            default: return true
            }
        }
        let missing = selected.filter { $0.account.isEmpty || $0.funding.isEmpty }.count
        let dups = items.filter { $0.duplicate != nil }.count
        return List {
            Section {
                LabeledContent(LS("文件"), value: fileName)
                Picker(LS("来源"), selection: $source) {
                    ForEach(ImportSource.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .onChange(of: source) { _, _ in if let t = table { build(t) } }
                Button { pickDefault = true } label: {
                    LabeledContent(LS("默认付款账户"), value: defaultFunding.isEmpty ? LS("未设置") : acctDisplay(defaultFunding))
                }
                .foregroundStyle(.primary)
                Toggle(LS("写入订单号（order 元数据，用于去重）"), isOn: $keepOrder)
                if source == .bank || table?.columns.date ?? -1 < 0 { columnsLink }
            } footer: {
                Text(LS("共 %@ 笔，已选 %@ 笔；%@ 笔疑似已记账（默认不选）；跳过 %@ 行（交易关闭、失败或无法识别）。不计收支的转账默认不选。", items.count, selected.count, dups, table?.skipped ?? 0))
            }
            Section {
                Picker(LS("显示"), selection: $filter) {
                    Text(LS("全部")).tag(0)
                    Text(LS("已选")).tag(1)
                    Text(LS("待选科目")).tag(2)
                    Text(LS("疑似重复")).tag(3)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if missing > 0 {
                    Label(LS("%@ 笔已选交易还没有科目或付款账户", missing), systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.warn)
                }
                HStack {
                    Button(LS("全选")) { for i in items.indices where shown.contains(where: { $0.id == items[i].id }) { items[i].include = true } }
                    Spacer()
                    Button(LS("全不选")) { for i in items.indices where shown.contains(where: { $0.id == items[i].id }) { items[i].include = false } }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
            Section {
                ForEach(shown) { it in row(it) }
            }
        }
        .listSectionSpacing(.compact)
    }

    private var columnsLink: some View {
        DisclosureGroup(LS("列对应关系"), isExpanded: $showColumns) {
            if let t = table {
                columnPicker(LS("日期"), \.date, t)
                columnPicker(LS("金额（正负）"), \.amount, t)
                columnPicker(LS("支出金额"), \.debit, t)
                columnPicker(LS("收入金额"), \.credit, t)
                columnPicker(LS("收付款方"), \.payee, t)
                columnPicker(LS("摘要"), \.narration, t)
                columnPicker(LS("收/支"), \.direction, t)
            }
        }
    }

    private func columnPicker(_ title: String, _ kp: WritableKeyPath<ImportColumns, Int>, _ t: ImportTable) -> some View {
        Picker(title, selection: Binding(get: { t.columns[keyPath: kp] }, set: { v in
            var c = t.columns
            c[keyPath: kp] = v
            if let d = data { load(d, name: fileName, columns: c) }
        })) {
            Text(LS("无")).tag(-1)
            ForEach(Array(t.header.enumerated()), id: \.offset) { i, h in Text(h.isEmpty ? LS("第 %@ 列", i + 1) : h).tag(i) }
        }
    }

    private func row(_ it: ImportItem) -> some View {
        let r = it.row
        let sign = r.direction == .income ? "+" : r.direction == .expense ? "-" : ""
        return HStack(alignment: .top, spacing: 10) {
            Button {
                if let i = items.firstIndex(where: { $0.id == it.id }) { items[i].include.toggle() }
            } label: {
                Image(systemName: it.include ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(it.include ? Color.jade : Color.secondary)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.payee.isEmpty ? LS("（无收付款方）") : r.payee).lineLimit(1)
                    Spacer()
                    Text(sign + money(r.amount)).monospacedDigit()
                        .foregroundStyle(r.direction == .income ? Color.gain : Color.primary).sensitive()
                }
                Text([r.date + (r.time.isEmpty ? "" : " " + r.time), r.narration, r.method].filter { !$0.isEmpty && $0 != "/" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Button { pickAccount = it.id } label: {
                        Text(it.account.isEmpty ? LS("选择科目") : acctLabel(it.account))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(it.account.isEmpty ? Color.warn.opacity(0.15) : Color.jade.opacity(0.12), in: Capsule())
                            .foregroundStyle(it.account.isEmpty ? Color.warn : Color.jade)
                    }
                    .buttonStyle(.borderless)
                    Button { pickFunding = it.id } label: {
                        Text(it.funding.isEmpty ? LS("付款账户") : acctLabel(it.funding))
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(it.funding.isEmpty ? Color.warn : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    if r.direction == .neutral { Tag(text: LS("不计收支")) }
                    if it.duplicate != nil { Tag(text: LS("疑似已记"), warn: true) }
                }
                if let d = it.duplicate {
                    Text(LS("账本中已有：%@ %@", d.date, [d.payee, d.narration].filter { !$0.isEmpty }.joined(separator: " ")))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(it.include ? 1 : 0.6)
    }

    // MARK: save

    private func save() {
        let rows = selected.filter { !$0.account.isEmpty && !$0.funding.isEmpty }.sorted { $0.row.date < $1.row.date }
        guard !rows.isEmpty else { return }
        let text = rows.map { importText($0.row, account: $0.account, funding: $0.funding, keepOrder: keepOrder) }.joined(separator: "\n\n")
        guard let ops = store.makeOps(text, extra: OpExtra(label: LS("导入账单：%@ 笔（%@）", rows.count, source.name)), single: false) else { return }
        Task {
            guard let checked = await store.review(ops) else { return }
            dismiss()
            await store.commit(checked, word: LS("已导入 %@ 笔", rows.count), checked: true)
        }
    }
}

struct IntBox: Identifiable { let v: Int; var id: Int { v } }
