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
    /// 待确认 (picked, something missing), 可导入 (picked and complete), 已跳过 (not picked)
    @State private var tab = Tab.pending
    @State private var showSettings = false
    enum Tab: Int { case pending, ready, skipped }
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
        let funds = t.rows.map { r in map[source.rawValue + "|" + r.method] ?? guessFunding(r.method, source: source, L, D) ?? defaultFunding }
        let dups = findDuplicates(zip(t.rows, funds).map { (row: $0.0, funding: $0.1.isEmpty ? nil : $0.1) }, L)
        items = t.rows.enumerated().map { i, r in
            let fund = funds[i]
            let acct = guessCategory(r, L, D) ?? ""
            let dup = dups[i]
            return ImportItem(row: r, include: dup == nil && r.direction != .neutral, account: acct, funding: fund, duplicate: dup)
        }.sorted { $0.row.date != $1.row.date ? $0.row.date > $1.row.date : $0.row.time > $1.row.time }
        tab = pending.isEmpty ? .ready : .pending
    }

    private func recheckDuplicates() {
        guard let L = store.L else { return }
        let dups = findDuplicates(items.map { (row: $0.row, funding: $0.funding.isEmpty ? nil : $0.funding) }, L)
        for i in items.indices {
            let d = dups[i]
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
    private func complete(_ it: ImportItem) -> Bool { !it.account.isEmpty && !it.funding.isEmpty }
    /// picked but missing a category or an account
    private var pending: [ImportItem] { items.filter { $0.include && !complete($0) } }
    private var ready: [ImportItem] { items.filter { $0.include && complete($0) } }
    private var skipped: [ImportItem] { items.filter { !$0.include } }

    /// the first one still missing something: its category, else its account
    private func next() {
        guard let it = pending.first else { return }
        tab = .pending
        if it.account.isEmpty { pickAccount = it.id } else { pickFunding = it.id }
    }

    /// every other line from the same payee (and direction) gets this one's category, set by hand or not
    private func applyToSame(_ it: ImportItem) {
        for k in items.indices where items[k].row.payee == it.row.payee && items[k].row.direction == it.row.direction {
            items[k].account = it.account
            items[k].manual = true
        }
        store.show(LS("已应用到「%@」的 %@ 笔", it.row.payee, items.filter { $0.row.payee == it.row.payee }.count))
    }

    // MARK: list

    private func list(_ L: Ledger, _ D: Derived) -> some View {
        let shown: [ImportItem] = tab == .pending ? pending : tab == .ready ? ready : skipped
        let dups = items.filter { $0.duplicate != nil }.count
        return List {
            Section { steps.cardRow() }
            Section {
                HStack(spacing: 12) {
                    IconBadge(symbol: "doc.text", color: .jade, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LS("%@账单", source.name)).font(.headline)
                        Text(fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { withAnimation { showSettings.toggle() } } label: {
                        Image(systemName: "slider.horizontal.3").font(.body)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(LS("导入设置"))
                }
                HStack(spacing: 0) {
                    stat(ready.count, LS("可导入"), .primary)
                    Divider().frame(height: 30)
                    stat(pending.count, LS("待确认"), pending.isEmpty ? .primary : .orange)
                    Divider().frame(height: 30)
                    stat(skipped.count + (table?.skipped ?? 0), LS("已跳过"), .secondary)
                }
                if showSettings {
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
                }
            } footer: {
                if showSettings {
                    Text(LS("共 %@ 笔；%@ 笔疑似已记账（默认跳过）；另有 %@ 行交易关闭、失败或无法识别。不计收支的转账默认跳过。", items.count, dups, table?.skipped ?? 0))
                }
            }
            if !pending.isEmpty {
                Section {
                    Button { next() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.orange)
                            Text(LS("还有 %@ 笔需要补充信息", pending.count)).foregroundStyle(Color.orange)
                            Spacer()
                            Text(LS("处理这 %@ 笔", pending.count)).fontWeight(.semibold).foregroundStyle(Color.orange)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.orange)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .cardRow()
                }
            }
            Section {
                Picker(LS("显示"), selection: $tab) {
                    Text(LS("待确认 %@", pending.count)).tag(Tab.pending)
                    Text(LS("可导入 %@", ready.count)).tag(Tab.ready)
                    Text(LS("已跳过 %@", skipped.count)).tag(Tab.skipped)
                }
                .pickerStyle(.segmented)
                .cardRow()
            }
            if shown.isEmpty {
                Section { Text(tab == .pending ? LS("没有要补充的了") : LS("这里没有记录")).foregroundStyle(.secondary) }
            }
            ForEach(shown) { it in Section { row(it) } }
        }
        .listSectionSpacing(.compact)
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    /// 选择文件 → 处理待确认 → 确认导入
    private var steps: some View {
        let at = pending.isEmpty ? 3 : 2
        return HStack(spacing: 6) {
            step(1, LS("选择文件"), at)
            line(at > 1)
            step(2, LS("处理待确认"), at)
            line(at > 2)
            step(3, LS("确认导入"), at)
        }
        .padding(.horizontal, 4)
    }

    private func step(_ n: Int, _ title: String, _ at: Int) -> some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(n < at ? Color.jade : n == at ? Color.jade : Color(.tertiarySystemFill)).frame(width: 22, height: 22)
                if n < at { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(Color.onJade) }
                else { Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(n == at ? Color.onJade : Color.secondary) }
            }
            Text(title).font(.caption.weight(n == at ? .semibold : .regular)).foregroundStyle(n == at ? Color.jade : Color.secondary)
                .lineLimit(1).fixedSize()
        }
    }

    private func line(_ done: Bool) -> some View {
        Rectangle().fill(done ? Color.jade.opacity(0.5) : Color(.separator)).frame(height: 1).frame(maxWidth: .infinity)
    }

    private func stat(_ n: Int, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(LS("%@ 笔", n)).font(.headline.monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 处理下一项 while something is missing (and 仅导入已确认的 N 笔); then 导入 N 笔
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if !pending.isEmpty {
                Button { next() } label: { Text(LS("处理下一项")).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                if !ready.isEmpty {
                    Button { save() } label: { Text(LS("仅导入已确认的 %@ 笔", ready.count)).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                    Text(LS("待确认的不会写入，留在这里可以稍后再导入。")).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Button { save() } label: { Text(ready.isEmpty ? LS("没有可导入的记录") : LS("导入 %@ 笔", ready.count)).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(ready.isEmpty)
            }
        }
        .tint(.jade)
        .controlSize(.large)
        .fontWeight(.semibold)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
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
        let same = items.filter { $0.row.payee == r.payee && $0.row.direction == r.direction }.count
        return Group {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    if let i = items.firstIndex(where: { $0.id == it.id }) { withAnimation { items[i].include.toggle() } }
                } label: {
                    Image(systemName: it.include ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(it.include ? Color.jade : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(it.include ? LS("跳过这笔") : LS("导入这笔"))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.payee.isEmpty ? LS("商户未知") : r.payee).font(.headline).lineLimit(1)
                        Spacer()
                        Text(sign + money(r.amount)).font(.headline.monospacedDigit())
                            .foregroundStyle(r.direction == .income ? Color.gain : Color.primary).sensitive()
                    }
                    Text([r.date + (r.time.isEmpty ? "" : " " + r.time), r.narration].filter { !$0.isEmpty && $0 != "/" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        if r.direction == .neutral { Tag(text: LS("不计收支")) }
                        if it.duplicate != nil { Tag(text: LS("疑似已记"), warn: true) }
                    }
                    if let d = it.duplicate {
                        Text(LS("账本中已有：%@ %@", d.date, [d.payee, d.narration].filter { !$0.isEmpty }.joined(separator: " ")))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .opacity(it.include ? 1 : 0.6)
            pickRow(LS("分类"), value: it.account.isEmpty ? nil : acctLabel(it.account), missing: LS("请选择分类")) { pickAccount = it.id }
            pickRow(r.direction == .income ? LS("收款账户") : LS("付款账户"), value: it.funding.isEmpty ? nil : acctLabel(it.funding),
                    missing: LS("请选择账户"), note: r.method.isEmpty || r.method == "/" ? nil : r.method) { pickFunding = it.id }
            if !it.account.isEmpty && same > 1 && !r.payee.isEmpty {
                Button { applyToSame(it) } label: {
                    Label(LS("应用到同类商户（%@ 笔）", same), systemImage: "square.on.square").font(.subheadline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func pickRow(_ label: String, value: String?, missing: String, note: String? = nil, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                Text(label).foregroundStyle(.secondary)
                if let n = note { Text(n).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer()
                if let v = value {
                    Text(v).foregroundStyle(.primary).lineLimit(1)
                } else {
                    Label(missing, systemImage: "exclamationmark.circle.fill").foregroundStyle(Color.orange)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
