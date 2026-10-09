import SwiftUI
import UIKit
import UniformTypeIdentifiers
import LedgerKit

/// BQL editor: edit, run, save, export
struct QueryEditorView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let initial: SavedQuery

    @State private var q = SavedQuery(name: "", text: "", source: "new")
    @State private var text = ""
    @State private var result: QueryResult?
    @State private var error: String?
    @State private var running = false
    @State private var ms = 0
    @State private var naming = false
    @State private var saveAsCopy = false
    @State private var newName = ""
    @State private var showRef = false
    @State private var loaded = false
    @FocusState private var editing: Bool

    private var isMine: Bool { q.source == "mine" }
    private var dirty: Bool { text.trimmed != q.text.trimmed }

    var body: some View {
        List {
            Section {
                TextEditor(text: $text)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($editing)
                    .frame(minHeight: 132)
                    .scrollContentBackground(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                ChipRow {
                    ForEach(snippets, id: \.self) { s in
                        Button { insert(s) } label: {
                            Text(s).font(.caption.monospaced())
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            } header: {
                HStack {
                    Text(sourceLabel)
                    Spacer()
                    Button { showRef = true } label: { Label(LS("语法参考"), systemImage: "book") }
                        .font(.caption).textCase(nil)
                }
            }

            Section {
                Button { run() } label: {
                    HStack {
                        if running { ProgressView().tint(Color.onJade) } else { Image(systemName: "play.fill") }
                        Text(LS("运行查询")).fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(running || text.trimmed.isEmpty)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if let e = error {
                Section {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.loss)
                        .textSelection(.enabled)
                }
            }

            if let r = result {
                Section {
                    if r.rows.isEmpty {
                        Text(LS("查询结果为空")).foregroundStyle(.secondary)
                    } else {
                        ResultTable(result: r)
                            .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                    }
                } header: {
                    HStack {
                        Text(LS("结果 · %@ 行 × %@ 列", r.rows.count, r.columns.count))
                        Spacer()
                        Text("\(ms) ms").textCase(nil)
                    }
                } footer: {
                    if r.rows.count > ResultTable.limit { Text(LS("仅显示前 %@ 行；导出 CSV 可获得完整结果。", ResultTable.limit)) }
                }
            }
        }
        .listSectionSpacing(.compact)
        .keyboardDone()
        .navigationTitle(q.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showRef) { QueryReference { insert($0) } }
        .alert(saveAsCopy ? LS("另存为") : LS("保存查询"), isPresented: $naming) {
            TextField(LS("查询名称"), text: $newName)
            Button(LS("取消"), role: .cancel) {}
            Button(LS("保存")) { save(name: newName, copy: saveAsCopy) }
        } message: {
            Text(LS("保存在本机，显示在「我的查询」中。"))
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            q = initial
            text = initial.text
            if initial.source == "new" { editing = true } else { run() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if isMine {
                    Button { save(name: q.name, copy: false) } label: { Label(LS("保存"), systemImage: "square.and.arrow.down") }
                        .disabled(!dirty)
                    Button { newName = q.name; saveAsCopy = false; naming = true } label: { Label(LS("重命名"), systemImage: "pencil") }
                }
                Button {
                    newName = isMine ? q.name + LS(" 副本") : (q.source == "new" ? "" : q.title)
                    saveAsCopy = true
                    naming = true
                } label: { Label(isMine ? LS("另存为…") : LS("保存到我的查询…"), systemImage: "plus.square.on.square") }
                Divider()
                Button {
                    UIPasteboard.general.string = text
                    store.show(LS("已复制查询语句"))
                } label: { Label(LS("复制查询语句"), systemImage: "doc.on.doc") }
                if let r = result, !r.rows.isEmpty {
                    Button {
                        UIPasteboard.general.string = csv(r)
                        store.show(LS("已复制 %@ 行（CSV）", r.rows.count))
                    } label: { Label(LS("复制结果（CSV）"), systemImage: "tablecells") }
                    ShareLink(item: CSVFile(name: q.name, text: csv(r)), preview: SharePreview(q.name + ".csv")) {
                        Label(LS("导出 CSV"), systemImage: "square.and.arrow.up")
                    }
                }
                if isMine {
                    Divider()
                    Button(role: .destructive) {
                        store.deleteQuery(q.id)
                        dismiss()
                    } label: { Label(LS("删除查询"), systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var sourceLabel: String {
        switch q.source {
        case "builtin": return LS("内置查询（修改后可另存）")
        case "ledger": return LS("来自账本（修改后可另存）")
        case "mine": return dirty ? LS("我的查询 · 未保存") : LS("我的查询")
        default: return LS("新建查询")
        }
    }

    private let snippets = ["SELECT", "WHERE", "GROUP BY", "ORDER BY", "DESC", "LIMIT 20", "SUM(position)", "CONVERT(position, 'CNY')",
                            "COUNT(*)", "account ~ \"^Expenses:\"", "year = YEAR(TODAY())", "month =", "date >=", "payee", "narration"]

    private func insert(_ s: String) {
        let needsSpace = !(text.last.map { $0 == " " || $0 == "\n" || $0 == "(" } ?? true)
        text += (needsSpace ? " " : "") + s
    }

    private func run() {
        guard let L = store.L, !running else { return }
        hideKeyboard()
        running = true
        let src = text
        Task {
            let start = Date()
            let out: Result<QueryResult, Error> = await Task.detached(priority: .userInitiated) {
                Result { try runQuery(src, L) }
            }.value
            ms = Int(Date().timeIntervalSince(start) * 1000)
            running = false
            switch out {
            case .success(let r): result = r; error = nil
            case .failure(let e): error = (e as? QueryError)?.message ?? e.localizedDescription; result = nil
            }
        }
    }

    private func save(name: String, copy: Bool) {
        let n = name.trimmed.isEmpty ? LS("未命名查询") : name.trimmed
        var x = q
        if copy || !isMine { x = SavedQuery(name: n, text: text.trimmed, source: "mine") }
        else { x.name = n; x.text = text.trimmed }
        store.saveQuery(x)
        q = x
        text = x.text
        store.show(LS("已保存「%@」", n))
    }

    private func csv(_ r: QueryResult) -> String {
        func esc(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var lines = [r.columns.map(esc).joined(separator: ",")]
        for row in r.rows { lines.append(row.map { esc($0.text) }.joined(separator: ",")) }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// a CSV file for the share sheet
struct CSVFile: Transferable {
    let name: String
    let text: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { Data($0.text.utf8) }
            .suggestedFileName { $0.name + ".csv" }
    }
}

// MARK: - results

func cellText(_ v: QValue) -> String {
    func num(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e12 { return abs(n) < 10000 ? String(Int64(n)) : fmtNum(n, 0) }
        return fmtNum(n, abs(n) < 1 ? 4 : 2)
    }
    func amt(_ n: Double) -> String { fmtNum(n, abs(n) < 1 && n != 0 ? 4 : 2) }
    switch v {
    case .number(let n): return num(n)
    case .amount(let n, let c): return amt(n) + " " + c
    case .inventory(let i):
        let parts = i.nonZero
        return parts.isEmpty ? "0" : parts.map { amt($0.1) + " " + $0.0 }.joined(separator: "\n")
    default: return v.text
    }
}

struct ResultTable: View {
    static let limit = 500
    let result: QueryResult

    var body: some View {
        let rows = Array(result.rows.prefix(Self.limit))
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                GridRow {
                    ForEach(result.columns.indices, id: \.self) { c in
                        Text(result.columns[c])
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(result.numeric[c] ? .trailing : .leading)
                            .padding(.vertical, 6)
                    }
                }
                Divider()
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        ForEach(result.columns.indices, id: \.self) { c in
                            cell(rows[i][c], numeric: result.numeric[c]).padding(.vertical, 6)
                        }
                    }
                    if i < rows.count - 1 { Divider().opacity(0.6) }
                }
            }
            .padding(.horizontal, 16)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func cell(_ v: QValue, numeric: Bool) -> some View {
        let t = cellText(v)
        if numeric {
            Text(t)
                .font(.footnote.monospacedDigit())
                .foregroundStyle((v.sortNumber ?? 0) < -1e-9 ? Color.loss : Color.primary)
                .multilineTextAlignment(.trailing)
                .fixedSize()
                .sensitive()
        } else {
            Text(t)
                .font(.footnote)
                .lineLimit(2)
                .frame(maxWidth: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - reference

struct QueryReference: View {
    @Environment(\.dismiss) private var dismiss
    let insert: (String) -> Void

    static var columns: [(String, String)] { [
        ("date", LS("交易日期")), ("year", LS("年份")), ("month", LS("月份")), ("day", LS("日")), ("quarter", LS("季度")),
        ("flag", LS("标记（* 或 !）")), ("payee", LS("收付款方")), ("narration", LS("摘要")), ("description", LS("收付款方与摘要")),
        ("tags", LS("标签集合")), ("links", LS("链接集合")), ("account", LS("科目")), ("other_accounts", LS("同一交易中的其他科目")),
        ("position", LS("持仓（数量、币种与成本）")), ("units", LS("数量与币种")), ("number", LS("数量")), ("currency", LS("币种")),
        ("cost_number", LS("单位成本")), ("cost_currency", LS("成本币种")), ("price", LS("价格")), ("weight", LS("权重（按成本或价格折算）")),
        ("balance", LS("累计余额（非汇总查询）")), ("filename", LS("所在文件")), ("lineno", LS("行号")), ("id", LS("交易标识")),
    ] }
    static var functions: [(String, String)] { [
        ("SUM(x)", LS("求和（金额按币种汇总）")), ("COUNT(*)", LS("计数")), ("FIRST(x)", LS("首个值")), ("LAST(x)", LS("末个值")), ("MIN(x)", LS("最小值")), ("MAX(x)", LS("最大值")),
        ("YEAR(date)", LS("取年份")), ("MONTH(date)", LS("取月份")), ("DAY(date)", LS("取日")), ("QUARTER(date)", LS("取季度")), ("YMONTH(date)", LS("年月，如 2026-10")),
        ("TODAY()", LS("今天")), ("PARENT(account)", LS("上级科目")), ("LEAF(account)", LS("末级科目名")), ("ROOT(account, n)", LS("前 n 级科目")),
        ("CONVERT(x, 'CNY')", LS("按最新价格折算币种")), ("VALUE(position)", LS("按市价折算为本位币")), ("COST(position)", LS("成本金额")),
        ("UNITS(position)", LS("数量")), ("NUMBER(x)", LS("取数值")), ("CURRENCY(x)", LS("取币种")), ("ABS(x)", LS("绝对值")), ("NEG(x)", LS("取反")),
        ("POSSIGN(x, account)", LS("按科目方向调整符号")), ("GREP(pattern, s)", LS("正则提取")), ("STR(x)", LS("转为文本")),
        ("LOWER(s)", LS("小写")), ("UPPER(s)", LS("大写")), ("LENGTH(x)", LS("长度")), ("COALESCE(a, b)", LS("首个非空值")), ("ONLY(c, inv)", LS("取指定币种")),
    ] }
    static var syntax: [(String, String)] { [
        (LS("SELECT [DISTINCT] 列 [AS 别名], …"), LS("选择列，可使用函数与算术运算")),
        (LS("FROM 条件"), LS("按交易过滤：交易内任一分录满足即保留")),
        (LS("WHERE 条件"), LS("按分录过滤")),
        (LS("GROUP BY 列 | 序号 | 别名"), LS("分组汇总")),
        (LS("ORDER BY 列 [ASC|DESC]"), LS("排序")),
        ("LIMIT n", LS("限制行数")),
        ("BALANCES [WHERE …]", LS("各科目余额")),
        (LS("JOURNAL \"正则\""), LS("科目日记账，含累计余额")),
        ("= != < <= > >=", LS("比较")),
        ("~  !~", LS("正则匹配（不区分大小写）")),
        ("'x' IN tags", LS("集合包含")),
        ("AND  OR  NOT  IS NULL", LS("逻辑运算")),
        ("date >= TODAY() - 30", LS("日期加减天数")),
    ] }

    var body: some View {
        NavigationStack {
            List {
                Section(LS("语法")) {
                    ForEach(Self.syntax, id: \.0) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.0).font(.subheadline.monospaced())
                            Text(s.1).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(Self.columns, id: \.0) { c in row(c.0, c.1) }
                } header: {
                    Text(LS("列"))
                } footer: {
                    Text(LS("点按可插入到查询末尾。"))
                }
                Section(LS("函数")) {
                    ForEach(Self.functions, id: \.0) { f in row(f.0, f.1) }
                }
            }
            .navigationTitle(LS("BQL 语法参考"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(LS("完成")) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ code: String, _ desc: String) -> some View {
        Button {
            insert(code)
            dismiss()
        } label: {
            HStack {
                Text(code).font(.subheadline.monospaced()).foregroundStyle(Color.jade)
                Spacer()
                Text(desc).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
    }
}
