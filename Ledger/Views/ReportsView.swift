import SwiftUI
import Charts
import LedgerKit

enum ReportKind: String, Hashable { case income, balance, trial }
struct QueryDest: Hashable { var query: SavedQuery }

// MARK: - the 报表 tab

struct ReportsView: View {
    @EnvironmentObject var store: Store
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: ReportKind.income) {
                        ReportRow(symbol: "chart.bar.doc.horizontal", color: .green, title: "损益表", detail: "收入、支出与净收益")
                    }
                    NavigationLink(value: ReportKind.balance) {
                        ReportRow(symbol: "building.columns", color: .blue, title: "资产负债表", detail: "资产、负债、权益与净资产走势")
                    }
                    NavigationLink(value: ReportKind.trial) {
                        ReportRow(symbol: "scale.3d", color: .orange, title: "试算平衡表", detail: "全部科目余额与借贷平衡校验")
                    }
                } header: {
                    Text("财务报表")
                }

                querySection("常用查询", builtinQueries)
                if !store.ledgerQueries.isEmpty { querySection("账本中的查询", store.ledgerQueries) }

                Section {
                    ForEach(store.myQueries) { q in
                        NavigationLink(value: QueryDest(query: q)) { QueryRow(q: q) }
                    }
                    .onDelete { idx in
                        let ids = idx.map { store.myQueries[$0].id }
                        ids.forEach(store.deleteQuery)
                    }
                    Button {
                        path.append(QueryDest(query: SavedQuery(id: "new", name: "新建查询", text: newQueryTemplate, source: "new")))
                    } label: {
                        Label("新建查询", systemImage: "plus")
                    }
                } header: {
                    Text("我的查询")
                } footer: {
                    Text("支持 Beancount 查询语言（BQL）的常用子集：SELECT … FROM … WHERE … GROUP BY … ORDER BY … LIMIT，以及 BALANCES、JOURNAL。账本中的 query 指令与 .bql 文件会自动列出。")
                }
            }
            .navigationTitle("报表")
            .toolbar { StandardToolbar() }
            .navigationDestination(for: ReportKind.self) { k in
                switch k {
                case .income: IncomeStatementView()
                case .balance: BalanceSheetView()
                case .trial: TrialBalanceView()
                }
            }
            .navigationDestination(for: QueryDest.self) { QueryEditorView(initial: $0.query) }
            .navigationDestination(for: AccountDest.self) { RegisterView(account: $0.name) }
            .navigationDestination(for: TxDest.self) { TxDetailView(dest: $0) }
            .navigationDestination(for: EditDest.self) { EditTxView(dest: $0) }
        }
        .onChange(of: store.popToken) { _, _ in path = NavigationPath() }
        .task {
            guard path.isEmpty, let r = store.demoEnv["LEDGER_REPORT"] else { return }
            if let k = ReportKind(rawValue: r) { path.append(k) }
            else if let q = (builtinQueries + store.ledgerQueries).first(where: { $0.id == r || $0.name == r }) { path.append(QueryDest(query: q)) }
        }
    }

    private var newQueryTemplate: String {
        "SELECT date, payee, narration, account, position\nWHERE account ~ \"^Expenses:\"\nORDER BY date DESC\nLIMIT 50"
    }

    private func querySection(_ title: String, _ qs: [SavedQuery]) -> some View {
        Section(title) {
            ForEach(qs) { q in
                NavigationLink(value: QueryDest(query: q)) { QueryRow(q: q) }
            }
        }
    }
}

struct ReportRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct QueryRow: View {
    let q: SavedQuery
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(q.name)
            Text(q.text.replacingOccurrences(of: "\n", with: " "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - periods

enum ReportPeriod: String, CaseIterable, Identifiable {
    case thisMonth, lastMonth, thisYear, lastYear, last12, all, custom
    var id: String { rawValue }
    var name: String {
        switch self {
        case .thisMonth: return "本月"
        case .lastMonth: return "上月"
        case .thisYear: return "本年"
        case .lastYear: return "上年"
        case .last12: return "近 12 个月"
        case .all: return "全部"
        case .custom: return "自定义"
        }
    }

    func range(today: String, from: String, to: String) -> (String?, String?) {
        let m = Day.ym(today)
        let y = String(today.prefix(4))
        switch self {
        case .thisMonth: return (m + "-01", Day.monthEnd(m))
        case .lastMonth: let p = Day.addMonth(m, -1); return (p + "-01", Day.monthEnd(p))
        case .thisYear: return (y + "-01-01", y + "-12-31")
        case .lastYear: let p = String((Int(y) ?? 2000) - 1); return (p + "-01-01", p + "-12-31")
        case .last12: return (Day.addMonth(m, -11) + "-01", Day.monthEnd(m))
        case .all: return (nil, nil)
        case .custom: return (min(from, to), max(from, to))
        }
    }
}

func rangeLabel(_ r: (String?, String?)) -> String {
    switch r {
    case (nil, nil): return "全部期间"
    case (let f?, let t?): return "\(f) 至 \(t)"
    case (let f?, nil): return "\(f) 起"
    case (nil, let t?): return "截至 \(t)"
    }
}

// MARK: - account tree rows

/// an expandable account tree inside a List section
struct AccountTreeRows: View {
    let root: AccountNode
    /// 1 for debit-normal roots (Assets, Expenses), -1 for credit-normal (Income, Liabilities, Equity)
    let sign: Double
    var share: Double? = nil
    @State private var expanded: Set<String> = []

    var body: some View {
        if root.children.isEmpty {
            Text("无发生额").foregroundStyle(.secondary)
        }
        ForEach(visible(), id: \.0.name) { pair in
            let node = pair.0
            let depth = pair.1
            NavigationLink(value: AccountDest(name: node.name)) {
                HStack(spacing: 6) {
                    if depth > 0 { Color.clear.frame(width: CGFloat(depth) * 14, height: 1) }
                    if !node.children.isEmpty {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                if expanded.contains(node.name) { expanded.remove(node.name) } else { expanded.insert(node.name) }
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expanded.contains(node.name) ? 90 : 0))
                                .frame(width: 18, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Color.clear.frame(width: 18, height: 1)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.label).lineLimit(1)
                        if depth == 0, let zh = ZH[node.label] { Text(zh).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(money(node.total * sign, "CNY")).monospacedDigit()
                            .font(depth == 0 ? .body : .subheadline)
                            .foregroundStyle(node.total * sign < -0.005 ? Color.loss : Color.primary)
                            .sensitive()
                        if let s = share, s > 0.005, depth == 0 {
                            Text(String(format: "%.1f%%", node.total * sign / s * 100)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func visible() -> [(AccountNode, Int)] {
        var out: [(AccountNode, Int)] = []
        func walk(_ n: AccountNode, _ d: Int) {
            out.append((n, d))
            if expanded.contains(n.name) { for c in n.children { walk(c, d + 1) } }
        }
        for c in root.children { walk(c, 0) }
        return out
    }
}

struct SectionTotal: View {
    let title: String
    let value: Double
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(money(value)).monospacedDigit().sensitive()
        }
    }
}

// MARK: - 损益表

struct IncomeStatementView: View {
    @EnvironmentObject var store: Store
    @AppStorage("ledger.report.period") private var period = ReportPeriod.thisYear
    @State private var from = Day.addMonth(Day.ym(Day.today()), -2) + "-01"
    @State private var to = Day.today()
    @State private var picked: String?

    var body: some View {
        Group {
            if let L = store.L, let D = store.D { content(L, D) } else { ProgressView() }
        }
        .navigationTitle("损益表")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func months(_ r: (String?, String?), _ D: Derived) -> [String] {
        let today = Day.today()
        let first = r.0.map { Day.ym($0) } ?? (D.monthExp.keys.min() ?? Day.ym(today))
        var last = r.1.map { Day.ym($0) } ?? Day.ym(today)
        if last > Day.ym(today) { last = Day.ym(today) }
        var out: [String] = []
        var m = first
        while m <= last && out.count < 120 { out.append(m); m = Day.addMonth(m, 1) }
        return Array(out.suffix(24))
    }

    private func content(_ L: Ledger, _ D: Derived) -> some View {
        let r = period.range(today: Day.today(), from: from, to: to)
        let s = incomeStatement(L, from: r.0, to: r.1)
        let inc = -s.income.total
        let exp = s.expenses.total
        let ms = months(r, D)
        return List {
            Section {
                PeriodChips(period: $period)
                if period == .custom {
                    DatePicker("开始", selection: dateBinding($from), displayedComponents: .date)
                    DatePicker("结束", selection: dateBinding($to), displayedComponents: .date)
                }
            }
            Section {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(rangeLabel(r)).font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("净收益").font(.subheadline).foregroundStyle(.secondary)
                            Text(money(s.net)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(s.net < 0 ? Color.loss : Color.primary).sensitive()
                        }
                        HStack(alignment: .top) {
                            Figure(label: "收入", value: money(inc), color: .gain)
                            Spacer()
                            Figure(label: "支出", value: money(exp))
                            Spacer()
                            Figure(label: "储蓄率", value: inc > 0 ? String(format: "%.1f%%", s.net / inc * 100) : "—", alignment: .trailing)
                        }
                        if inc > 0 || exp > 0 {
                            RatioBar(parts: [(inc, Color.gain), (exp, Color.jade)])
                        }
                    }
                }
                .cardRow()
            }
            if ms.count > 1 {
                Section {
                    IncomeExpenseChart(months: ms, D: D, picked: $picked)
                } header: {
                    Text("月度收支")
                }
            }
            Section {
                AccountTreeRows(root: s.income, sign: -1, share: inc)
            } header: {
                SectionTotal(title: "收入", value: inc)
            }
            Section {
                AccountTreeRows(root: s.expenses, sign: 1, share: exp)
            } header: {
                SectionTotal(title: "支出", value: exp)
            } footer: {
                Text("金额按期末汇率折算为 \(L.base)。收入以正数列示。")
            }
        }
        .listSectionSpacing(.compact)
    }
}

func dateBinding(_ s: Binding<String>) -> Binding<Date> {
    Binding(get: { Day.date(s.wrappedValue) ?? Date() }, set: { s.wrappedValue = Day.string($0) })
}

struct PeriodChips: View {
    @Binding var period: ReportPeriod
    var body: some View {
        ChipRow {
            ForEach(ReportPeriod.allCases) { p in
                Chip(label: p.name, selected: p == period) { withAnimation(.snappy) { period = p } }
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }
}

/// a stacked horizontal bar of shares
struct RatioBar: View {
    let parts: [(Double, Color)]
    var body: some View {
        let total = max(parts.reduce(0) { $0 + max(0, $1.0) }, 1e-9)
        GeometryReader { g in
            HStack(spacing: 3) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    if p.0 > 0 {
                        Capsule().fill(p.1.gradient).frame(width: max(4, (g.size.width - 3) * p.0 / total))
                    }
                }
            }
        }
        .frame(height: 8)
        .sensitive()
    }
}

struct IncomeExpenseChart: View {
    let months: [String]
    let D: Derived
    @Binding var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(months, id: \.self) { m in
                    BarMark(x: .value("月份", m), y: .value("金额", D.monthInc[m] ?? 0))
                        .foregroundStyle(by: .value("类别", "收入"))
                        .position(by: .value("类别", "收入"))
                        .cornerRadius(3)
                        .opacity(picked == nil || picked == m ? 1 : 0.35)
                    BarMark(x: .value("月份", m), y: .value("金额", D.monthExp[m] ?? 0))
                        .foregroundStyle(by: .value("类别", "支出"))
                        .position(by: .value("类别", "支出"))
                        .cornerRadius(3)
                        .opacity(picked == nil || picked == m ? 1 : 0.35)
                }
            }
            .chartForegroundStyleScale(["收入": Color.gain, "支出": Color.jade])
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis { AxisMarks(position: .trailing) }
            .chartXAxis {
                AxisMarks { v in
                    AxisValueLabel {
                        if let s = v.as(String.self) { Text(s.hasSuffix("-01") ? String(s.prefix(4)) : String(Int(s.suffix(2)) ?? 0)) }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geo[plot].origin.x
                            guard let m: String = proxy.value(atX: x) else { return }
                            withAnimation(.easeOut(duration: 0.15)) { picked = picked == m ? nil : m }
                        }
                }
            }
            .frame(height: 190)
            .sensitive()
            if let m = picked {
                let i = D.monthInc[m] ?? 0, e = D.monthExp[m] ?? 0
                HStack(spacing: 14) {
                    Text(Day.monthLabel(m)).fontWeight(.medium)
                    Text("收入 " + money(i)).foregroundStyle(Color.gain)
                    Text("支出 " + money(e))
                    Spacer()
                    Text("结余 " + money(i - e)).foregroundStyle(i - e < 0 ? Color.loss : Color.secondary)
                }
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .sensitive()
            } else {
                Text("点按柱形查看当月明细").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 资产负债表

enum AsOf: String, CaseIterable, Identifiable {
    case today, lastMonthEnd, lastYearEnd, custom
    var id: String { rawValue }
    var name: String {
        switch self {
        case .today: return "今日"
        case .lastMonthEnd: return "上月末"
        case .lastYearEnd: return "上年末"
        case .custom: return "指定日期"
        }
    }
    func date(today: String, custom: String) -> String {
        switch self {
        case .today: return today
        case .lastMonthEnd: return Day.monthEnd(Day.addMonth(Day.ym(today), -1))
        case .lastYearEnd: return String((Int(today.prefix(4)) ?? 2000) - 1) + "-12-31"
        case .custom: return custom
        }
    }
}

struct BalanceSheetView: View {
    @EnvironmentObject var store: Store
    @State private var asOf = AsOf.today
    @State private var custom = Day.today()
    @AppStorage("ledger.report.nwRange") private var nwRange = 24
    @State private var pickedMonth: Date?

    var body: some View {
        Group {
            if let L = store.L { content(L) } else { ProgressView() }
        }
        .navigationTitle("资产负债表")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ L: Ledger) -> some View {
        let date = asOf.date(today: Day.today(), custom: custom)
        let bs = balanceSheet(L, at: date)
        let assets = bs.assets.total
        let liab = -bs.liabilities.total
        let series = Array(netWorthSeries(L, today: Day.today()).suffix(nwRange == 0 ? 10_000 : nwRange))
        return List {
            Section {
                ChipRow {
                    ForEach(AsOf.allCases) { a in
                        Chip(label: a.name, selected: a == asOf) { withAnimation(.snappy) { asOf = a } }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                if asOf == .custom {
                    DatePicker("截至日期", selection: dateBinding($custom), displayedComponents: .date)
                }
            }
            Section {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("截至 \(date)").font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("净资产").font(.subheadline).foregroundStyle(.secondary)
                            Text(money(bs.netWorth)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit().sensitive()
                        }
                        HStack(alignment: .top) {
                            Figure(label: "资产总额", value: money(assets))
                            Spacer()
                            Figure(label: "负债总额", value: money(liab), color: liab > 0.005 ? Color.loss : Color.primary)
                            Spacer()
                            Figure(label: "资产负债率", value: assets > 0 && liab > 0.005 ? String(format: "%.1f%%", liab / assets * 100) : "—", alignment: .trailing)
                        }
                        RatioBar(parts: [(max(0, assets - liab), Color.jade), (liab, Color.loss)])
                    }
                }
                .cardRow()
            }
            if series.count > 1 {
                Section {
                    NetWorthChart(series: series, picked: $pickedMonth)
                    Picker("区间", selection: $nwRange) {
                        Text("1 年").tag(12)
                        Text("2 年").tag(24)
                        Text("5 年").tag(60)
                        Text("全部").tag(0)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("净资产走势")
                }
            }
            Section {
                AccountTreeRows(root: bs.assets, sign: 1)
            } header: {
                SectionTotal(title: "资产", value: assets)
            }
            Section {
                AccountTreeRows(root: bs.liabilities, sign: -1)
            } header: {
                SectionTotal(title: "负债", value: liab)
            }
            Section {
                AccountTreeRows(root: bs.equity, sign: -1)
                HStack {
                    Text("未结转损益").foregroundStyle(.secondary)
                    Spacer()
                    Text(money(-bs.earnings)).monospacedDigit().sensitive()
                }
            } header: {
                SectionTotal(title: "权益", value: -bs.equity.total - bs.earnings)
            } footer: {
                Text("未结转损益为期初至截止日的收入减支出（Fava 中的 Equity:Earnings:Current）。资产 = 负债 + 权益；外币按截止日汇率折算为 \(L.base)。")
            }
        }
        .listSectionSpacing(.compact)
    }
}

struct NetWorthChart: View {
    let series: [NetWorthPoint]
    @Binding var picked: Date?

    private func date(_ m: String) -> Date { Day.date(m + "-01") ?? Date() }

    var body: some View {
        let sel = picked.flatMap { p in series.min { abs(date($0.month).timeIntervalSince(p)) < abs(date($1.month).timeIntervalSince(p)) } }
        let lo = series.map { $0.netWorth }.min() ?? 0
        let hi = series.map { $0.netWorth }.max() ?? 0
        let pad = max((hi - lo) * 0.1, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let s = sel {
                    Text(Day.monthLabel(s.month) + "末").foregroundStyle(.secondary)
                    Spacer()
                    Text(money(s.netWorth)).fontWeight(.semibold).monospacedDigit().sensitive()
                } else if let last = series.last, let first = series.first {
                    Text("区间变动").foregroundStyle(.secondary)
                    Spacer()
                    Text(signedMoney(last.netWorth - first.netWorth)).fontWeight(.semibold).monospacedDigit()
                        .foregroundStyle(last.netWorth >= first.netWorth ? Color.gain : Color.loss).sensitive()
                }
            }
            .font(.subheadline)
            Chart(series) { p in
                AreaMark(x: .value("月份", date(p.month), unit: .month), yStart: .value("下限", lo - pad), yEnd: .value("净资产", p.netWorth))
                    .foregroundStyle(LinearGradient(colors: [Color.jade.opacity(0.32), Color.jade.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("月份", date(p.month), unit: .month), y: .value("净资产", p.netWorth))
                    .foregroundStyle(Color.jade)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .interpolationMethod(.monotone)
                if let s = sel, s.month == p.month {
                    PointMark(x: .value("月份", date(p.month), unit: .month), y: .value("净资产", p.netWorth))
                        .foregroundStyle(Color.jade)
                        .symbolSize(70)
                    RuleMark(x: .value("月份", date(p.month), unit: .month))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartYAxis { AxisMarks(position: .trailing) }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let plot = proxy.plotFrame else { return }
                            guard let d: Date = proxy.value(atX: location.x - geo[plot].origin.x) else { return }
                            withAnimation(.easeOut(duration: 0.15)) {
                                if let p = picked, abs(p.timeIntervalSince(d)) < 86400 * 15 { picked = nil } else { picked = d }
                            }
                        }
                }
            }
            .frame(height: 180)
            .sensitive()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 试算平衡表

struct TrialBalanceView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if let L = store.L { content(L) } else { ProgressView() }
        }
        .navigationTitle("试算平衡表")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ L: Ledger) -> some View {
        let today = Day.today()
        let b = periodBalances(L, to: today)
        let roots = ["Assets", "Liabilities", "Equity", "Income", "Expenses"].map { accountTree(b, root: $0, L, at: today) }
        let debit = roots.reduce(0.0) { $0 + max(0, $1.total) }
        let credit = roots.reduce(0.0) { $0 + max(0, -$1.total) }
        let diff = roots.reduce(0.0) { $0 + $1.total }
        return List {
            Section {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("截至 \(today) · 原始符号（借方为正，贷方为负）").font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .top) {
                            Figure(label: "借方合计", value: money(debit))
                            Spacer()
                            Figure(label: "贷方合计", value: money(credit))
                            Spacer()
                            Figure(label: "差额", value: money(diff), color: abs(diff) < 0.5 ? Color.gain : Color.warn, alignment: .trailing)
                        }
                        Label(abs(diff) < 0.5 ? "借贷平衡" : "存在差额（多为外币折算或缺少价格所致）",
                              systemImage: abs(diff) < 0.5 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(abs(diff) < 0.5 ? Color.gain : Color.warn)
                    }
                }
                .cardRow()
            }
            ForEach(roots, id: \.name) { r in
                Section {
                    AccountTreeRows(root: r, sign: 1)
                } header: {
                    SectionTotal(title: r.name + " · " + (ZH[r.name] ?? ""), value: r.total)
                }
            }
        }
        .listSectionSpacing(.compact)
    }
}
