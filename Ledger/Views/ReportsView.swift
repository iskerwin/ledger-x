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
                ReportsInsights(path: $path)
                Section {
                    NavigationLink(value: YearReviewDest()) {
                        ReportRow(symbol: "sparkles", color: .orange, title: LS("年度回顾"), detail: LS("全年收支、净资产、支出构成、工资与大事"))
                    }
                    NavigationLink(value: ReportKind.income) {
                        ReportRow(symbol: "chart.bar.doc.horizontal", color: .green, title: LS("损益表"), detail: LS("收入、支出与净收益"))
                    }
                    NavigationLink(value: ReportKind.balance) {
                        ReportRow(symbol: "building.columns", color: .blue, title: LS("资产负债表"), detail: LS("资产、负债、权益与净资产走势"))
                    }
                    NavigationLink(value: ReportKind.trial) {
                        ReportRow(symbol: "scale.3d", color: .orange, title: LS("试算平衡表"), detail: LS("全部科目余额与借贷平衡校验"))
                    }
                    NavigationLink(value: BudgetsDest()) {
                        ReportRow(symbol: "chart.bar.doc.horizontal.fill", color: .purple, title: LS("预算"), detail: LS("按月 / 按年的分类额度与执行进度"))
                    }
                    NavigationLink(value: ForecastDest()) {
                        ReportRow(symbol: "chart.line.uptrend.xyaxis", color: .teal, title: LS("现金流预测"), detail: LS("未来 30～90 天可用资金走势与收支"))
                    }
                    NavigationLink(value: SubscriptionsDest()) {
                        ReportRow(symbol: "repeat", color: .indigo, title: LS("订阅管理"), detail: LS("周期扣费、到期提醒与一键入账"))
                    }
                    NavigationLink(value: ReimbursementsDest()) {
                        ReportRow(symbol: "doc.text", color: .mint, title: LS("报销"), detail: LS("待报销、备用金、报销单与历史明细，导出报销单"))
                    }
                    NavigationLink(value: SalaryDest()) {
                        ReportRow(symbol: "banknote", color: .green, title: LS("工资"), detail: LS("按工资条逐项记工资，每年税前收入与扣款"))
                    }
                    NavigationLink(value: EventsDest()) {
                        ReportRow(symbol: "flag", color: .pink, title: LS("事件"), detail: LS("出差、旅行等按 #标签汇总的花费"))
                    }
                    NavigationLink(value: PayeesDest()) {
                        ReportRow(symbol: "person.2", color: .brown, title: LS("收付款方"), detail: LS("使用次数与金额，重命名、合并商户"))
                    }
                    NavigationLink(value: AlertsDest()) {
                        ReportRow(symbol: "exclamationmark.triangle", color: .orange, title: LS("值得留意"), detail: LS("重复扣款、大额支出、分类超常、订阅调价"))
                    }
                } header: {
                    Text(LS("更多报表"))
                }

                querySection(LS("常用查询"), builtinQueries)

                Section {
                    ForEach(store.ledgerQueries) { q in
                        NavigationLink(value: QueryDest(query: q)) { QueryRow(q: q) }
                            .deleteDisabled(!store.isEditableQuery(q))
                    }
                    .onDelete { idx in
                        // one file at a time, from the last one, so the positions of the others hold
                        let qs = idx.map { store.ledgerQueries[$0] }.sorted { (bqlLocation($0.id)?.index ?? 0) > (bqlLocation($1.id)?.index ?? 0) }
                        Task { for q in qs { await store.deleteQuery(q) } }
                    }
                    Button {
                        path.append(QueryDest(query: SavedQuery(id: "new", name: LS("新建查询"), text: newQueryTemplate, source: "new")))
                    } label: {
                        Label(LS("新建查询"), systemImage: "plus")
                    }
                } header: {
                    Text(LS("我的查询"))
                } footer: {
                    Text(LS("保存在账本的 %@ 中，所有设备同步；左滑可删除。支持 Beancount 查询语言（BQL）的常用子集：SELECT … FROM … WHERE … GROUP BY … ORDER BY … LIMIT，以及 BALANCES、JOURNAL。账本中的 query 指令与其他 .bql 文件也会列在这里。", Store.customQueries))
                }

                if !store.myQueries.isEmpty {
                    Section {
                        ForEach(store.myQueries) { q in
                            NavigationLink(value: QueryDest(query: q)) { QueryRow(q: q) }
                        }
                        .onDelete { idx in
                            let qs = idx.map { store.myQueries[$0] }
                            Task { for q in qs { await store.deleteQuery(q) } }
                        }
                        Button { Task { await store.moveLocalQueries() } } label: {
                            Label(LS("全部移到账本"), systemImage: "arrow.up.doc")
                        }
                    } header: {
                        Text(LS("本机查询（未同步）"))
                    } footer: {
                        Text(LS("旧版本保存在这台手机上的查询。移到账本后所有设备都能看到。"))
                    }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle(LS("报表"))
            .toolbar { StandardToolbar() }
            .navigationDestination(for: ReportKind.self) { k in
                Group {
                    switch k {
                    case .income: IncomeStatementView()
                    case .balance: BalanceSheetView()
                    case .trial: TrialBalanceView()
                    }
                }
                .privacyToolbar(currency: true)
            }
            .navigationDestination(for: YearReviewDest.self) { YearReviewView(year: $0.year).privacyToolbar(currency: true) }
            .navigationDestination(for: BudgetsDest.self) { _ in BudgetsView().privacyToolbar() }
            .navigationDestination(for: SubscriptionsDest.self) { _ in SubscriptionsView().privacyToolbar() }
            .navigationDestination(for: ForecastDest.self) { _ in ForecastView().privacyToolbar() }
            .navigationDestination(for: EventsDest.self) { _ in EventsView().privacyToolbar() }
            .navigationDestination(for: SalaryDest.self) { _ in SalaryView().privacyToolbar() }
            .navigationDestination(for: EventDest.self) { EventDetailView(tag: $0.tag).privacyToolbar() }
            .navigationDestination(for: AlertsDest.self) { _ in AlertsView().privacyToolbar() }
            .navigationDestination(for: PayeesDest.self) { _ in PayeesView().privacyToolbar() }
            .navigationDestination(for: PayeeDest.self) { PayeeDetailView(name: $0.name).privacyToolbar() }
            .navigationDestination(for: AnomalyDest.self) { AnomalyDetailView(id: $0.id).privacyToolbar() }
            .navigationDestination(for: QueryDest.self) { QueryEditorView(initial: $0.query).privacyToolbar() }
            .navigationDestination(for: AccountDest.self) { RegisterView(account: $0.name).privacyToolbar() }
            .navigationDestination(for: TxDest.self) { TxDetailView(dest: $0).privacyToolbar() }
            .subscriptionDestinations()
            .navigationDestination(for: EditDest.self) { EditTxView(dest: $0) }
        }
        // on the stack itself: the pages it opens inherit what is set here, not what is set on its first page
        .pushes(onto: $path)
        .onChange(of: store.popToken) { _, _ in path = NavigationPath() }
        .task {
            guard path.isEmpty, let r = store.demoEnv["LEDGER_REPORT"] else { return }
            if r == "year" { path.append(YearReviewDest(year: store.demoEnv["LEDGER_YEAR"])) }
            else if r == "budgets" { path.append(BudgetsDest()) }
            else if r == "subscriptions" { path.append(SubscriptionsDest()) }
            else if r == "forecast" { path.append(ForecastDest()) }
            else if r == "events" { path.append(EventsDest()) }
            else if r == "reimb" { path.append(ReimbursementsDest()) }
            else if r == "reimb-batch", let b = store.L.flatMap({ reimbBatches($0).first }) { path.append(ReimbursementsDest()); path.append(ReimbBatchDest(link: b.link)) }
            else if let k = ReportKind(rawValue: r) { path.append(k) }
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
            Text(q.title)
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
        case .thisMonth: return LS("本月")
        case .lastMonth: return LS("上月")
        case .thisYear: return LS("本年")
        case .lastYear: return LS("上年")
        case .last12: return LS("近 12 个月")
        case .all: return LS("全部")
        case .custom: return LS("自定义")
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
    case (nil, nil): return LS("全部期间")
    case (let f?, let t?): return LS("%@ 至 %@", f, t)
    case (let f?, nil): return LS("%@ 起", f)
    case (nil, let t?): return LS("截至 %@", t)
    }
}

// MARK: - account tree rows

/// an expandable account tree inside a List section
struct AccountTreeRows: View {
    @EnvironmentObject var store: Store
    let root: AccountNode
    /// 1 for debit-normal roots (Assets, Expenses), -1 for credit-normal (Income, Liabilities, Equity)
    let sign: Double
    /// percentages of this total beside the first level (when the section is in one currency)
    var share: Double? = nil
    var base = "CNY"
    @State private var expanded: Set<String> = []

    var body: some View {
        if root.children.isEmpty {
            Text(LS("无发生额")).foregroundStyle(.secondary)
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
                    // the same group icon as 管理账户 and the 记一笔 grid; sub-accounts line up under the name
                    if depth == 0 {
                        let k = store.groupIcon(node.name)
                        IconBadge(symbol: k.symbol, color: k.color, size: 26)
                    } else {
                        Color.clear.frame(width: 26, height: 1)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.label).lineLimit(1)
                        if depth == 0, AppLanguage.current != .en, let zh = acctZH(node.name) ?? ZH[node.label] { Text(zh).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        // the balance as the report's 显示方式 values it: one line per currency
                        let xs = node.shown.byCurrency(base: base)
                        ForEach(xs.isEmpty ? [CurrencyAmount(base, 0)] : xs) { x in
                            Text(unitText(x.amount * sign, x.currency)).monospacedDigit()
                                .font(depth == 0 ? .body : .subheadline)
                                .foregroundStyle(x.amount * sign < -0.005 ? Color.loss : Color.primary)
                                .sensitive()
                        }
                        if let s = share, s > 0.005, depth == 0, let x = node.shown.single(base: base) {
                            Text(String(format: "%.1f%%", x.amount * sign / s * 100)).font(.caption2).foregroundStyle(.secondary)
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
    /// by currency instead (one line each)
    var amounts: [CurrencyAmount]? = nil
    var body: some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer()
            if let xs = amounts {
                VStack(alignment: .trailing, spacing: 1) {
                    if xs.isEmpty { Text(money(0)).monospacedDigit().sensitive() }
                    ForEach(xs) { x in Text(unitText(x.amount, x.currency)).monospacedDigit().sensitive() }
                }
            } else {
                Text(money(value)).monospacedDigit().sensitive()
            }
        }
    }
}

/// an amount as booked: money for a currency, a plain quantity for shares and other commodities
func unitText(_ v: Double, _ c: String) -> String {
    let currency = SYM[c] != nil || (c.count == 3 && c.allSatisfy { $0.isLetter })
    if currency { return money(v, c) }
    let cents = abs(v * 100 - (v * 100).rounded()) < 1e-6
    let whole = abs(v - v.rounded()) < 1e-9
    return money(v, c, whole ? 0 : cents ? 2 : 4)
}

/// what 折算为 offers: the operating currencies, then the other currencies that have a rate (not shares)
func reportCurrencies(_ L: Ledger) -> [String] {
    var out: [String] = [L.base]
    for o in L.options["operating_currency"] ?? [] { if let c = o, !out.contains(c) { out.append(c) } }
    for c in L.rates.keys.sorted() where !out.contains(c) {
        let code = c.count >= 3 && c.count <= 4 && c.allSatisfy { $0.isUppercase && $0.isLetter }
        let equity = L.commodities[c]?["asset-class"]?.display.contains("equity") ?? false
        if code && !equity { out.append(c) }
    }
    return out
}

extension ReportMode {
    /// what the line that balances each currency is called
    var conversionsTitle: String {
        switch self {
        case .units, .cost: return LS("货币兑换")
        case .market: return LS("货币兑换与未实现损益")
        case .convert: return LS("折算差额")
        }
    }

    /// how the accounts are shown, for a footer
    func explain(_ L: Ledger) -> String {
        switch self {
        case .units: return LS("原币：按记账时的币种列示，证券按数量，不折算，可以直接和银行、券商账单对。")
        case .cost: return LS("按成本：按成本持有的证券（如 10 AAPL {80 USD}）按成本列示为成本货币，其余按原币。")
        case .market: return LS("按市值：按成本持有的证券按截止日价格折算为成本货币，其余按原币。")
        case .convert(let c): return LS("折算为 %@：全部按截止日汇率折算；没有汇率的仍按原币列出。", c)
        }
    }
}

/// one row of the equity section by currency (未结转损益, 货币兑换)
struct CurrencyLinesRow: View {
    let title: String
    let amounts: [CurrencyAmount]
    var body: some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if amounts.isEmpty { Text(money(0)).monospacedDigit().sensitive() }
                ForEach(amounts) { x in Text(unitText(x.amount, x.currency)).monospacedDigit().sensitive() }
            }
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
        .navigationTitle(LS("损益表"))
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
        let mode = store.cmode, only = store.conly
        let s = incomeStatement(L, from: r.0, to: r.1, mode: mode, only: only)
        let inc = -s.income.shown, exp = s.expenses.shown
        let net = inc + (-exp)
        // one currency: a figure each, the savings rate and the bar; several: a line per currency
        let one = [inc, exp, net].allSatisfy { $0.single(base: L.base) != nil }
            && Set([inc, exp].compactMap { $0.single(base: L.base) }.filter { abs($0.amount) > 0.005 }.map { $0.currency }).count <= 1
        let i1 = inc.single(base: L.base)?.amount ?? 0, e1 = exp.single(base: L.base)?.amount ?? 0
        let ms = months(r, D)
        return List {
            Section {
                PeriodChips(period: $period)
                if period == .custom {
                    DatePicker(LS("开始"), selection: dateBinding($from), displayedComponents: .date)
                    DatePicker(LS("结束"), selection: dateBinding($to), displayedComponents: .date)
                }
                CurrencyBanner()
            }
            Section {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(rangeLabel(r)).font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LS("净收益")).font(.subheadline).foregroundStyle(.secondary)
                            InventoryHeadline(inv: net, base: L.base)
                        }
                        HStack(alignment: .top) {
                            InventoryFigure(label: LS("收入"), inv: inc, base: L.base, color: .gain)
                            Spacer()
                            InventoryFigure(label: LS("支出"), inv: exp, base: L.base)
                            Spacer()
                            Figure(label: LS("储蓄率"), value: one && i1 > 0 ? String(format: "%.1f%%", (i1 - e1) / i1 * 100) : "—", alignment: .trailing)
                        }
                        if one && (i1 > 0 || e1 > 0) {
                            RatioBar(parts: [(i1, Color.gain), (e1, Color.jade)])
                        }
                    }
                }
                .cardRow()
            }
            if ms.count > 1 {
                Section {
                    FlowCharts(months: ms, flows: monthlyFlows(L, months: ms, mode: mode, only: only), base: L.base, picked: $picked)
                } header: {
                    Text(LS("月度收支"))
                }
            }
            Section {
                AccountTreeRows(root: s.income, sign: -1, share: one ? i1 : nil, base: L.base)
            } header: {
                SectionTotal(title: LS("收入"), value: 0, amounts: inc.byCurrency(base: L.base))
            }
            Section {
                AccountTreeRows(root: s.expenses, sign: 1, share: one ? e1 : nil, base: L.base)
            } header: {
                SectionTotal(title: LS("支出"), value: 0, amounts: exp.byCurrency(base: L.base))
            } footer: {
                Text(mode.explain(L) + LS("收入以正数列示。"))
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
    /// income (positive) and expenses of each month, in `currency`
    let inc: [String: Double]
    let exp: [String: Double]
    var currency = "CNY"
    /// a small chart among several (one per currency): shorter, no tapping
    var compact = false
    @Binding var picked: String?

    /// the months that get a label: a step that keeps them apart, on months that divide by it (Jan, Apr, Jul, Oct…)
    private var labelled: [String] {
        let n = months.count
        let step = n <= 8 ? 1 : n <= 14 ? 2 : n <= 26 ? 3 : 6
        return months.filter { m in ((Int(m.suffix(2)) ?? 1) - 1) % step == 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(months, id: \.self) { m in
                    BarMark(x: .value("月份", m), y: .value("金额", inc[m] ?? 0))
                        .foregroundStyle(by: .value("类别", LS("收入")))
                        .position(by: .value("类别", LS("收入")))
                        .cornerRadius(3)
                        .opacity(picked == nil || picked == m ? 1 : 0.35)
                    BarMark(x: .value("月份", m), y: .value("金额", exp[m] ?? 0))
                        .foregroundStyle(by: .value("类别", LS("支出")))
                        .position(by: .value("类别", LS("支出")))
                        .cornerRadius(3)
                        .opacity(picked == nil || picked == m ? 1 : 0.35)
                }
            }
            .chartForegroundStyleScale([LS("收入"): Color.gain, LS("支出"): Color.jade])
            .chartLegend(compact ? .hidden : .visible)
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis { AxisMarks(position: .trailing) }
            .chartXAxis {
                // at most about 8 labels: every month, every 2nd, every quarter or every half year; January shows the year
                // when the months run over more than one
                let years = Set(months.map { $0.prefix(4) }).count
                AxisMarks(values: labelled) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let s = v.as(String.self) { Text(years > 1 && s.hasSuffix("-01") ? String(s.prefix(4)) : String(Int(s.suffix(2)) ?? 0)) }
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
            .frame(height: compact ? 130 : 190)
            .sensitive()
            if let m = picked {
                let i = inc[m] ?? 0, e = exp[m] ?? 0
                HStack(spacing: 14) {
                    Text(Day.monthLabel(m)).fontWeight(.medium)
                    Text(LS("收入 ") + money(i, currency)).foregroundStyle(Color.gain)
                    Text(LS("支出 ") + money(e, currency))
                    Spacer()
                    Text(LS("结余 ") + money(i - e, currency)).foregroundStyle(i - e < 0 ? Color.loss : Color.secondary)
                }
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .sensitive()
            } else if !compact {
                Text(LS("点按柱形查看当月明细")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

/// 月度收支 for the chosen currencies: one chart when it all comes to one currency, else one small chart each
/// (their sizes differ too much to share an axis)
struct FlowCharts: View {
    let months: [String]
    let flows: [String: MonthFlow]
    let base: String
    @Binding var picked: String?

    private var currencies: [String] {
        var all = Inventory()
        for f in flows.values {
            for (c, n) in f.income.nonZero { all.add(abs(n), c) }
            for (c, n) in f.expenses.nonZero { all.add(abs(n), c) }
        }
        return all.byCurrency(base: base).map { $0.currency }
    }

    private func series(_ c: String) -> ([String: Double], [String: Double]) {
        var i: [String: Double] = [:], e: [String: Double] = [:]
        for (m, f) in flows { i[m] = f.income.amounts[c] ?? 0; e[m] = f.expenses.amounts[c] ?? 0 }
        return (i, e)
    }

    var body: some View {
        let cs = currencies
        if cs.count <= 1 {
            let c = cs.first ?? base
            let x = series(c)
            IncomeExpenseChart(months: months, inc: x.0, exp: x.1, currency: c, picked: $picked)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Label(LS("收入"), systemImage: "circle.fill").foregroundStyle(Color.gain)
                    Label(LS("支出"), systemImage: "circle.fill").foregroundStyle(Color.jade)
                }
                .font(.caption).labelStyle(DotLabel())
                ForEach(cs, id: \.self) { c in
                    let x = series(c)
                    VStack(alignment: .leading, spacing: 2) {
                        CurrencyTitle(code: c)
                        IncomeExpenseChart(months: months, inc: x.0, exp: x.1, currency: c, compact: true, picked: $picked)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// a currency's name above its chart: its colour and code
struct CurrencyTitle: View {
    let code: String
    var trailing: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(currencyColor(code)).frame(width: 8, height: 8)
            Text(code).font(.caption.weight(.semibold))
            Spacer()
            if let t = trailing { Text(t).font(.caption.weight(.semibold)).monospacedDigit().sensitive() }
        }
    }
}

struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 7)); configuration.title.foregroundStyle(.secondary) }
    }
}

/// 净资产走势 for the chosen currencies.
/// - converted, several currencies held: stacked areas, one per currency held, with the total as a line
/// - one currency in the end: a single area
/// - as booked / at cost / at market in several currencies: one small chart each, on its own scale
struct WorthCharts: View {
    let slices: [WorthSlice]
    let base: String
    let mode: ReportMode
    @Binding var picked: Date?

    private func date(_ m: String) -> Date { Day.date(m + "-01") ?? Date() }

    /// the currencies the values end up in
    private var shown: [String] {
        var all = Inventory()
        for s in slices { for (c, n) in s.total.nonZero { all.add(abs(n), c) } }
        return all.byCurrency(base: base).map { $0.currency }
    }

    /// the currencies held, largest first
    private var sources: [String] {
        var size: [String: Double] = [:]
        for s in slices { for (c, inv) in s.bySource { size[c] = max(size[c] ?? 0, inv.nonZero.reduce(0) { $0 + abs($1.1) }) } }
        return size.filter { $0.value > 0.005 }.sorted { $0.value > $1.value }.map { $0.key }
    }

    var body: some View {
        let out = shown
        if out.count <= 1 {
            let c = out.first ?? base
            let pts = slices.map { NetWorthPoint(month: $0.month, assets: $0.total.amounts[c] ?? 0, liabilities: 0) }
            if mode.converted != nil && sources.count > 1 {
                stacked(c, pts)
            } else {
                NetWorthChart(series: pts, currency: c, picked: $picked)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(out, id: \.self) { c in
                    let pts = slices.map { NetWorthPoint(month: $0.month, assets: $0.total.amounts[c] ?? 0, liabilities: 0) }
                    VStack(alignment: .leading, spacing: 2) {
                        CurrencyTitle(code: c, trailing: pts.last.map { unitText($0.netWorth, c) })
                        NetWorthChart(series: pts, currency: c, compact: true, picked: $picked)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// from the lowest the negative layers reach to the highest the positive ones do (not a symmetric guess)
    private func stackRange(_ c: String, _ srcs: [String]) -> ClosedRange<Double> {
        var lo = 0.0, hi = 0.0
        for s in slices {
            var neg = 0.0, pos = 0.0
            for src in srcs { let v = s.bySource[src]?.amounts[c] ?? 0; if v < 0 { neg += v } else { pos += v } }
            lo = min(lo, neg); hi = max(hi, pos)
        }
        let pad = max((hi - lo) * 0.05, 1)
        return (lo < 0 ? lo - pad : 0)...(hi + pad)
    }

    /// stacked areas by currency held, all in `c`; tap a month for its parts
    private func stacked(_ c: String, _ total: [NetWorthPoint]) -> some View {
        let srcs = sources
        let sel = picked.flatMap { p in slices.min { abs(date($0.month).timeIntervalSince(p)) < abs(date($1.month).timeIntervalSince(p)) } }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let s = sel {
                    Text(Day.monthLabel(s.month) + LS("末")).foregroundStyle(.secondary)
                    Spacer()
                    Text(unitText(s.total.amounts[c] ?? 0, c)).fontWeight(.semibold).monospacedDigit().sensitive()
                } else if let last = total.last, let first = total.first {
                    Text(LS("区间变动")).foregroundStyle(.secondary)
                    Spacer()
                    Text((last.netWorth >= first.netWorth ? "+" : "") + unitText(last.netWorth - first.netWorth, c)).fontWeight(.semibold).monospacedDigit()
                        .foregroundStyle(last.netWorth >= first.netWorth ? Color.gain : Color.loss).sensitive()
                }
            }
            .font(.subheadline)
            Chart {
                ForEach(srcs, id: \.self) { src in
                    ForEach(slices) { s in
                        AreaMark(x: .value("月份", date(s.month), unit: .month), y: .value("金额", s.bySource[src]?.amounts[c] ?? 0))
                            .foregroundStyle(by: .value("币种", src))
                            .interpolationMethod(.monotone)
                    }
                }
                ForEach(total) { p in
                    LineMark(x: .value("月份", date(p.month), unit: .month), y: .value("合计", p.netWorth), series: .value("s", "total"))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                if let s = sel {
                    RuleMark(x: .value("月份", date(s.month), unit: .month))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartForegroundStyleScale(domain: srcs, range: srcs.map { currencyColor($0).opacity(0.75) })
            .chartYScale(domain: stackRange(c, srcs))
            .chartLegend(position: .top, alignment: .leading)
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
            .frame(height: 200)
            .sensitive()
            if let s = sel {
                // the parts of that month
                WrapLayout(spacing: 10) {
                    ForEach(srcs, id: \.self) { src in
                        HStack(spacing: 4) {
                            Circle().fill(currencyColor(src)).frame(width: 7, height: 7)
                            Text(src + " " + unitText(s.bySource[src]?.amounts[c] ?? 0, c)).monospacedDigit().sensitive()
                        }
                    }
                }
                .font(.caption)
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
        case .today: return LS("今日")
        case .lastMonthEnd: return LS("上月末")
        case .lastYearEnd: return LS("上年末")
        case .custom: return LS("指定日期")
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
        .navigationTitle(LS("资产负债表"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ L: Ledger) -> some View {
        let date = asOf.date(today: Day.today(), custom: custom)
        // each left out by its own list: the sheet by 资产负债表's, the trend by 净资产's
        let mode = store.cmode, only = store.conly
        let bs = balanceSheet(L, at: date, exclude: store.balanceExclude, mode: mode, only: only)
        let assets = bs.assets.shown, liab = -bs.liabilities.shown
        let a1 = assets.single(base: L.base), l1 = liab.single(base: L.base)
        // the ratio only means something in one currency
        let ratio: String = {
            guard let a = a1, let l = l1, a.currency == l.currency || abs(l.amount) < 0.005, a.amount > 0, l.amount > 0.005 else { return "—" }
            return String(format: "%.1f%%", l.amount / a.amount * 100)
        }()
        let series = Array(worthSeries(L, today: Day.today(), exclude: store.netWorthExclude, mode: mode, only: only).suffix(nwRange == 0 ? 10_000 : nwRange))
        return ScrollViewReader { proxy in List {
            Section {
                ChipRow {
                    ForEach(AsOf.allCases) { a in
                        Chip(label: a.name, selected: a == asOf) { withAnimation(.snappy) { asOf = a } }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                if asOf == .custom {
                    DatePicker(LS("截至日期"), selection: dateBinding($custom), displayedComponents: .date)
                }
                CurrencyBanner()
            }
            Section {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(LS("截至 %@", date)).font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LS("净资产")).font(.subheadline).foregroundStyle(.secondary)
                            InventoryHeadline(inv: bs.netWorthShown, base: L.base)
                        }
                        HStack(alignment: .top) {
                            InventoryFigure(label: LS("资产总额"), inv: assets, base: L.base)
                            Spacer()
                            InventoryFigure(label: LS("负债总额"), inv: liab, base: L.base)
                            Spacer()
                            Figure(label: LS("资产负债率"), value: ratio, alignment: .trailing)
                        }
                        if let a = a1, ratio != "—" || (l1?.amount ?? 0) < 0.005 {
                            let l = max(0, l1?.amount ?? 0)
                            RatioBar(parts: [(max(0, a.amount - l), Color.jade), (l, Color.loss)])
                        }
                    }
                }
                .cardRow()
            }
            if series.count > 1 {
                Section {
                    WorthCharts(slices: series, base: L.base, mode: mode, picked: $pickedMonth)
                        .id("trend")
                    Picker(LS("区间"), selection: $nwRange) {
                        Text(LS("1 年")).tag(12)
                        Text(LS("2 年")).tag(24)
                        Text(LS("5 年")).tag(60)
                        Text(LS("全部")).tag(0)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(LS("净资产走势"))
                }
            }
            Section {
                AccountTreeRows(root: bs.assets, sign: 1, base: L.base)
            } header: {
                SectionTotal(title: LS("资产"), value: 0, amounts: assets.byCurrency(base: L.base))
            }
            Section {
                AccountTreeRows(root: bs.liabilities, sign: -1, base: L.base)
            } header: {
                SectionTotal(title: LS("负债"), value: 0, amounts: liab.byCurrency(base: L.base))
            }
            Section {
                AccountTreeRows(root: bs.equity, sign: -1, base: L.base)
                CurrencyLinesRow(title: LS("未结转损益"), amounts: (-bs.earningsByCurrency).byCurrency(base: L.base))
                let conv = (-bs.conversions).byCurrency(base: L.base)
                if !conv.isEmpty { CurrencyLinesRow(title: mode.conversionsTitle, amounts: conv) }
            } header: {
                SectionTotal(title: LS("权益"), value: -bs.equity.total - bs.earnings, amounts: (-bs.equityByCurrency).byCurrency(base: L.base))
            } footer: {
                Text(mode.explain(L) + LS("每种货币各自平衡：资产 = 负债 + 权益。未结转损益是期初至截止日的收入减支出（Fava 的 Equity:Earnings）；%@（Fava 的 Equity:Conversions）补上换汇、外币消费、买卖证券以及价格和汇率变化在各币种之间留下的差额。", mode.conversionsTitle))
            }
            if !store.balanceExclude.isEmpty || !store.netWorthExclude.isEmpty {
                Section {
                    NavigationLink { NetWorthSettingsView(which: store.balanceExclude.isEmpty ? .netWorth : .balance) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            if !store.balanceExclude.isEmpty { Text(LS("资产负债表不列 %@ 个账户，合计不含它们，资产 ≠ 负债 + 权益", store.balanceExclude.count)) }
                            if !store.netWorthExclude.isEmpty { Text(LS("净资产走势不计入 %@ 个账户", store.netWorthExclude.count)) }
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .task {
            // screenshots: the trend in view
            guard store.demoEnv["LEDGER_SCROLL"] == "trend" else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
            proxy.scrollTo("trend", anchor: .top)
        }
        }
    }
}

struct NetWorthChart: View {
    let series: [NetWorthPoint]
    var currency = "CNY"
    /// a small chart among several: no heading line, shorter
    var compact = false
    @Binding var picked: Date?
    /// the theme colour on its own; a currency's colour among several
    private var tint: Color { compact ? currencyColor(currency) : Color.jade }

    private func date(_ m: String) -> Date { Day.date(m + "-01") ?? Date() }

    var body: some View {
        let sel = picked.flatMap { p in series.min { abs(date($0.month).timeIntervalSince(p)) < abs(date($1.month).timeIntervalSince(p)) } }
        let lo = series.map { $0.netWorth }.min() ?? 0
        let hi = series.map { $0.netWorth }.max() ?? 0
        let pad = max((hi - lo) * 0.1, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let s = sel {
                    Text(Day.monthLabel(s.month) + LS("末")).foregroundStyle(.secondary)
                    Spacer()
                    Text(unitText(s.netWorth, currency)).fontWeight(.semibold).monospacedDigit().sensitive()
                } else if let last = series.last, let first = series.first, !compact {
                    Text(LS("区间变动")).foregroundStyle(.secondary)
                    Spacer()
                    Text((last.netWorth >= first.netWorth && !KitPrivacy.masked ? "+" : "") + unitText(last.netWorth - first.netWorth, currency)).fontWeight(.semibold).monospacedDigit()
                        .foregroundStyle(last.netWorth >= first.netWorth ? Color.gain : Color.loss).sensitive()
                }
            }
            .font(compact ? .caption : .subheadline)
            Chart(series) { p in
                AreaMark(x: .value("月份", date(p.month), unit: .month), yStart: .value("下限", lo - pad), yEnd: .value("净资产", p.netWorth))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("月份", date(p.month), unit: .month), y: .value("净资产", p.netWorth))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .interpolationMethod(.monotone)
                if let s = sel, s.month == p.month {
                    PointMark(x: .value("月份", date(p.month), unit: .month), y: .value("净资产", p.netWorth))
                        .foregroundStyle(tint)
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
            .frame(height: compact ? 110 : 180)
            .sensitive()
        }
        .padding(.vertical, compact ? 0 : 6)
    }
}

// MARK: - 试算平衡表

struct TrialBalanceView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if let L = store.L { content(L) } else { ProgressView() }
        }
        .navigationTitle(LS("试算平衡表"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ L: Ledger) -> some View {
        let today = Day.today()
        let mode = store.cmode, only = store.conly
        let b = periodBalances(L, to: today, only: only)
        let v = mode == .units ? b : valuedBalances(L, to: today, mode: mode, only: only)
        let roots = ["Assets", "Liabilities", "Equity", "Income", "Expenses"].map { accountTree(b, root: $0, L, at: today, shown: v) }
        // what makes each currency balance: conversions, and with market values or rates the change since booking
        let conv = conversions(of: v)
        return List {
            if !store.cview.isDefault {
                Section { CurrencyBanner() }
            }
            Section {
                Card { totalsCard(roots, conv, L, today, mode) }.cardRow()
            }
            ForEach(roots, id: \.name) { r in
                Section {
                    AccountTreeRows(root: r, sign: 1, base: L.base)
                    if r.name == "Equity" {
                        let xs = conv.byCurrency(base: L.base)
                        if !xs.isEmpty { CurrencyLinesRow(title: mode.conversionsTitle, amounts: xs) }
                    }
                } header: {
                    SectionTotal(title: AppLanguage.current == .en ? r.name : r.name + " · " + (ZH[r.name] ?? ""), value: r.total,
                                 amounts: (r.name == "Equity" ? r.shown + conv : r.shown).byCurrency(base: L.base))
                }
            }
        }
        .listSectionSpacing(.compact)
    }

    /// debits and credits of each currency, equal once the conversions are counted
    private func totalsCard(_ roots: [AccountNode], _ conv: Inventory, _ L: Ledger, _ today: String, _ mode: ReportMode) -> some View {
        var debit: [String: Double] = [:], credit: [String: Double] = [:]
        for x in roots.map({ $0.shown }) + [conv] {
            for (c, v) in x.amounts { if v > 0 { debit[c, default: 0] += v } else { credit[c, default: 0] -= v } }
        }
        let all = roots.reduce(conv) { $0 + $1.shown }
        let ccys = Set(debit.keys).union(credit.keys).sorted { a, b in a == L.base ? b != L.base : b == L.base ? false : a < b }
            .filter { (debit[$0] ?? 0) > 0.005 || (credit[$0] ?? 0) > 0.005 }
        let ok = all.byCurrency(base: L.base).isEmpty
        // converted: whatever is still in its own currency has no rate
        let unpriced = mode.converted.map { x in ccys.filter { $0 != x } } ?? []
        let convNow = mode.converted.flatMap { conv.amounts[$0] } ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            Text(LS("截至 %@ · 原始符号（借方为正，贷方为负）", today)).font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text(LS("币种")).gridColumnAlignment(.leading)
                    Text(LS("借方合计"))
                    Text(LS("贷方合计"))
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(ccys, id: \.self) { c in
                    GridRow {
                        Text(c).font(.subheadline.weight(.medium)).gridColumnAlignment(.leading)
                        Text(unitText(debit[c] ?? 0, c)).monospacedDigit().sensitive()
                        Text(unitText(credit[c] ?? 0, c)).monospacedDigit().sensitive()
                    }
                    .font(.subheadline)
                }
            }
            if !unpriced.isEmpty {
                Label(LS("缺少价格：%@", unpriced.joined(separator: ", ")), systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium)).foregroundStyle(Color.warn)
            } else {
                Label(ok ? LS("每种货币借贷平衡") : LS("借贷不平衡"), systemImage: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(ok ? Color.gain : Color.warn)
            }
            Group {
                if let x = mode.converted {
                    Text(LS("折算差额 %@：每笔交易按记账时的汇率平衡，这里按截止日的价格折算，差额相当于未实现的汇兑与价格盈亏，不是账本错误。", unitText(convNow, x)))
                } else {
                    Text(mode.explain(L) + LS("各币种之间的差额记在「%@」（Fava 中的 Equity:Conversions）。", mode.conversionsTitle))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}
