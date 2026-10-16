import SwiftUI
import Charts
import LedgerKit

struct HoldingsDest: Hashable {}

/// 持仓: everything held at cost (stocks, funds), valued at the latest price. A summary on top, the holdings
/// filtered by the currency they are priced in and sorted, each a card that opens on its lots, K 线 and register.
struct HoldingsView: View {
    @EnvironmentObject var store: Store
    @State private var open: Set<String> = []
    @State private var pricing = false
    @State private var chart: ChartTarget?
    /// the quote currency shown (nil: all)
    @State private var market: String?
    @AppStorage("ledger.holdings.sort") private var sort = "value"
    /// opens the register from a card (a link of its own would take the whole card)
    @Environment(\.push) private var push

    var body: some View {
        Group {
            if let L = store.L { page(L) } else { ProgressView() }
        }
        .navigationTitle(LS("持仓"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { pricing = true } label: { Label(LS("更新价格"), systemImage: "arrow.clockwise") }
            }
        }
        .sheet(isPresented: $pricing) { PriceUpdateSheet() }
        .sheet(item: $chart) { t in if let L = store.L { KLineSheet(rows: holdings(L), selected: t.id) } }
        .task {
            if store.demoEnv["LEDGER_PRICES"] != nil { pricing = true }
            if store.demoEnv["LEDGER_HOLDING_OPEN"] != nil, let L = store.L, let first = sorted(holdings(L), L).first { open.insert(first.id) }
        }
    }

    private func cny(_ L: Ledger, _ n: Double, _ c: String) -> Double { toCNY(L, n, c) ?? 0 }

    /// a market by the currency its prices are in
    static func marketName(_ q: String) -> String {
        switch q {
        case "USD": return LS("美元")
        case "HKD": return LS("港元")
        case "CNY": return LS("人民币")
        default: return q
        }
    }

    private func sorted(_ rows: [Holding], _ L: Ledger) -> [Holding] {
        switch sort {
        case "pnl": return rows.sorted { pct($0) > pct($1) }
        case "name": return rows.sorted { $0.c != $1.c ? $0.c < $1.c : $0.acct < $1.acct }
        default: return rows.sorted { cny(L, $0.value ?? $0.cost, $0.q) > cny(L, $1.value ?? $1.cost, $1.q) }
        }
    }

    private func pct(_ r: Holding) -> Double { r.cost != 0 ? (r.pnl ?? 0) / r.cost : 0 }

    private func page(_ L: Ledger) -> some View {
        let all = holdings(L)
        let markets = Array(Set(all.map { $0.q })).sorted { a, b in
            let order = ["USD", "HKD", "CNY"]
            return (order.firstIndex(of: a) ?? 9, a) < (order.firstIndex(of: b) ?? 9, b)
        }
        let rows = sorted(all.filter { market == nil || $0.q == market }, L)
        return List {
            summary(L, all)
            // the markets to filter by when there is more than one; the order beside them, else beside 持仓明细
            if markets.count > 1 {
                Section {
                    HStack(spacing: 8) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Chip(label: LS("全部"), selected: market == nil) { market = nil }
                                ForEach(markets, id: \.self) { m in Chip(label: Self.marketName(m), selected: market == m) { market = market == m ? nil : m } }
                            }
                        }
                        sortMenu
                    }
                }
                .cardRow()
            }
            if rows.isEmpty {
                Section(LS("持仓明细")) { Text(LS("暂无以成本计价的持仓")).foregroundStyle(.secondary) }
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                Section {
                    holdingCard(r)
                } header: {
                    if i == 0 {
                        HStack {
                            Text(LS("持仓明细"))
                            Spacer()
                            if markets.count <= 1 && rows.count > 1 { sortMenu.textCase(nil) }
                        }
                    }
                }
            }
            incomeSection(L)
            Section {
                EmptyView()
            } footer: {
                Text(LS("市值只是持仓份额 × 最新价格（账本中最新的 price 指令），不含股息、利息和账户里的现金；这些收入列在「投资收入」，信用卡返现不算投资收益。成本取自买入时记录的 {成本}；卖出时按账户的批次匹配方法（如 FIFO）结转。"))
            }
        }
        .listSectionSpacing(.compact)
    }

    /// 市值 ↓ / 盈亏 ↓ / 名称 ↑
    private var sortMenu: some View {
        Menu {
            Picker(LS("排序"), selection: $sort) {
                Text(LS("市值")).tag("value")
                Text(LS("盈亏")).tag("pnl")
                Text(LS("名称")).tag("name")
            }
        } label: {
            HStack(spacing: 3) {
                Text(sort == "pnl" ? LS("盈亏") : sort == "name" ? LS("名称") : LS("市值"))
                Image(systemName: sort == "name" ? "arrow.up" : "arrow.down")
            }
            .font(.subheadline)
        }
    }

    /// 总市值, 持仓成本 | 浮动盈亏, 累计收益, when the prices are from
    private func summary(_ L: Ledger, _ rows: [Holding]) -> some View {
        let value = rows.reduce(0.0) { $0 + cny(L, $1.value ?? $1.cost, $1.q) }
        let cost = rows.reduce(0.0) { $0 + cny(L, $1.cost, $1.q) }
        let pxDate = rows.compactMap { $0.px?.date }.max()
        let income = investIncome(L, String(Day.today().prefix(4))).reduce(0.0) { $0 + $1.2 }
        let up = value >= cost
        return Section {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LS("总市值 · %@", L.base)).font(.subheadline).foregroundStyle(.secondary)
                        Text(money(value, L.base)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6).sensitive()
                    }
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LS("持仓成本")).font(.caption).foregroundStyle(.secondary)
                            Text(money(cost, L.base)).font(.callout.weight(.semibold).monospacedDigit()).sensitive()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider().frame(height: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LS("浮动盈亏")).font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text(signedMoney(value - cost, L.base)).font(.callout.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(up ? Color.gain : Color.loss).lineLimit(1).minimumScaleFactor(0.7)
                                if cost != 0 {
                                    Text(String(format: "%@%.1f%%", up ? "+" : "", (value - cost) / cost * 100))
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background((up ? Color.gain : Color.loss).opacity(0.14), in: Capsule())
                                        .foregroundStyle(up ? Color.gain : Color.loss)
                                }
                            }
                            .sensitive()
                        }
                        .padding(.leading, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if abs(income) > 0.005 {
                        Text(LS("累计收益 %@（浮动盈亏 + 已实现收益、股息、利息）", signedMoney(value - cost + income, L.base)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                    }
                    if let d = pxDate {
                        HStack(spacing: 6) {
                            Circle().fill(Day.shift(d, 3) >= Day.today() ? Color.gain : Color.warn).frame(width: 7, height: 7)
                            Text(LS("价格更新于 %@", d)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .cardRow()
        }
    }

    /// two letters for a ticker's badge
    private func monogram(_ c: String) -> String { String(c.prefix(c.count > 4 ? 2 : min(c.count, 4)).prefix(4)) }

    @ViewBuilder
    private func holdingCard(_ r: Holding) -> some View {
        let isOpen = open.contains(r.id)
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { if isOpen { open.remove(r.id) } else { open.insert(r.id) } }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    Text(monogram(r.c))
                        .font(.system(size: r.c.count > 3 ? 11 : 13, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(Color.jade)
                        .frame(width: 40, height: 40)
                        .background(Color.jade.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.c).font(.headline)
                        Text(acctLabel(r.acct) + " · " + Self.marketName(r.q)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(money(r.value ?? r.cost, r.q)).font(.body.weight(.semibold)).monospacedDigit().sensitive()
                        if let p = r.pnl {
                            Text(signedMoney(p, r.q) + (r.cost != 0 ? String(format: "  %@%.1f%%", p >= 0 ? "+" : "", p / r.cost * 100) : ""))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(p >= 0 ? Color.gain : Color.loss)
                                .sensitive()
                        } else {
                            Text(LS("无价格")).font(.caption).foregroundStyle(Color.warn)
                        }
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                if !isOpen {
                    Text(LS("持仓 %@ 份 · 均价 %@ · 现价 %@", masked(fmtNum(r.units, 4)), masked(fmtNum(r.avg, 2)), r.px.map { fmtNum($0.number, 2) } ?? "—"))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if isOpen {
            // 持仓 | 均价 | 现价
            HStack(spacing: 0) {
                stat(LS("持仓"), LS("%@ 份", masked(fmtNum(r.units, 4))))
                Divider().frame(height: 32)
                stat(LS("均价"), masked(fmtNum(r.avg, 2)), lead: true)
                Divider().frame(height: 32)
                stat(LS("现价"), r.px.map { fmtNum($0.number, 2) } ?? "—", lead: true)
            }
            .sensitive()
            VStack(alignment: .leading, spacing: 8) {
                Text(LS("买入批次")).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(r.lots.enumerated()), id: \.offset) { pair in lotRow(pair.element, r) }
            }
            HStack(spacing: 0) {
                Button { chart = ChartTarget(id: r.id) } label: {
                    Label(LS("K 线走势"), systemImage: "chart.bar.xaxis").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                Divider().frame(height: 22)
                Button { push?(AccountDest(name: r.acct)) } label: {
                    Label(LS("账户明细"), systemImage: "list.bullet.rectangle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
            }
            .font(.subheadline)
            .padding(.vertical, 2)
        }
    }

    private func stat(_ title: String, _ value: String, lead: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.leading, lead ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lotRow(_ l: Lot, _ r: Holding) -> some View {
        let c = l.cost
        let gain = r.px.map { l.units * ($0.number - (c?.number ?? 0)) }
        return HStack(spacing: 10) {
            Text((c?.date ?? "") + (c?.label.map { " · " + $0 } ?? "")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("\(masked(fmtNum(l.units, 4))) × \(masked(fmtNum(c?.number ?? 0, 4))) \(c?.currency ?? "")")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            if let g = gain {
                Text(signedMoney(g, r.q)).font(.caption.monospacedDigit()).foregroundStyle(g >= 0 ? Color.gain : Color.loss)
                    .frame(minWidth: 70, alignment: .trailing)
            }
        }
        .sensitive()
    }

    @ViewBuilder
    private func incomeSection(_ L: Ledger) -> some View {
        let year = String(Day.today().prefix(4))
        let rows = investIncome(L, year)
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.0) { row in
                    NavigationLink(value: AccountDest(name: row.0)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(leaf(row.0))
                                Text(Self.incomeZH[leaf(row.0)] ?? catLabel(row.0)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(money(row.1, L.base)).monospacedDigit().sensitive()
                                Text(LS("累计 ") + money(row.2, L.base)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                            }
                        }
                    }
                }
            } header: {
                Text(LS("投资收入 · %@ 年", year))
            }
        }
    }

    static var incomeZH: [String: String] { ["Gain": LS("已实现收益"), "Dividend": LS("股息"), "Interest": LS("利息"), "StockAward": LS("股票奖励"), "Coupon": LS("票息")] }

    /// Income:Invest:* (or any income account under an "Invest" group): (account, this year, all time)
    private func investIncome(_ L: Ledger, _ year: String) -> [(String, Double, Double)] {
        var ytd: [String: Double] = [:], all: [String: Double] = [:]
        for t in L.txns {
            for p in t.postings where p.units != nil && p.account.hasPrefix("Income:") && p.account.components(separatedBy: ":").contains(where: { $0.hasPrefix("Invest") }) {
                let v = -(toCNY(L, p.units!, p.currency ?? L.base, t.date) ?? 0)
                all[p.account, default: 0] += v
                if t.date.hasPrefix(year) { ytd[p.account, default: 0] += v }
            }
        }
        return all.keys.sorted { abs(all[$0]!) > abs(all[$1]!) }.map { ($0, ytd[$0] ?? 0, all[$0]!) }
    }
}


// MARK: - 更新价格

/// one row of the price sheet: a commodity or currency and the currency it is quoted in
struct PriceItem: Identifiable, Hashable {
    var id: String { c + "/" + q }
    let c: String
    let q: String
    let last: Double?
    let date: String?
}

/// write price directives for the held commodities and foreign currencies, all at once
struct PriceUpdateSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var date = Day.today()
    @State private var values: [String: String] = [:]
    @State private var fetching = false
    @State private var fetchNote: String?
    @AppStorage(PriceFetch.autoKey) private var auto = false
    @FocusState private var focus: String?

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L { form(L) } else { ProgressView() }
            }
            .keyboardDone()
            .navigationTitle(LS("更新价格"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LS("保存")) { save() }.fontWeight(.semibold).disabled(lines().isEmpty)
                }
            }
        }
    }

    static func items(_ L: Ledger) -> [PriceItem] {
        var seen = Set<String>()
        var out: [PriceItem] = []
        func add(_ c: String, _ q: String) {
            guard c != q, seen.insert(c + "/" + q).inserted else { return }
            let p = latestPrice(L, c, q)
            out.append(PriceItem(c: c, q: q, last: p?.number, date: p?.date))
        }
        for h in holdings(L) { add(h.c, h.q) }
        // foreign currencies held in assets or liabilities
        for (a, cs) in L.final.sorted(by: { $0.key < $1.key }) where a.hasPrefix("Assets") || a.hasPrefix("Liabilities") {
            for (c, n) in cs.sorted(by: { $0.key < $1.key }) where abs(n) > 0.005 && c.count == 3 && c.uppercased() == c && !holdings(L).contains(where: { $0.c == c }) {
                add(c, L.base)
            }
        }
        // anything else that already has prices
        for p in L.prices where !seen.contains(p.currency.map { $0 + "/" + (p.quote ?? "") } ?? "") {
            if let c = p.currency, let q = p.quote, out.count < 40 { add(c, q) }
        }
        return out
    }

    private func form(_ L: Ledger) -> some View {
        let items = Self.items(L)
        return Form {
            Section {
                DatePicker(LS("价格日期"), selection: dateBinding($date), displayedComponents: .date)
                Button {
                    Task { await fetch(L, items) }
                } label: {
                    HStack {
                        Label(LS("从 Yahoo Finance 获取最新价格"), systemImage: "arrow.down.circle")
                        if fetching { Spacer(); ProgressView() }
                    }
                }
                .disabled(fetching || items.isEmpty)
                if let n = fetchNote { Text(n).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text(LS("只会写入填写了新价格的项目，每项一条 price 指令。证券代码可在 commodity 的 price 元数据中指定，如 price: \"USD:yahoo/VOO\"、\"CNY:yahoo/510300.SS\"；外币默认按 USDCNY=X 查询。"))
            }
            Section {
                if items.isEmpty { Text(LS("没有需要报价的证券或外币")).foregroundStyle(.secondary) }
                ForEach(items) { it in
                    let days = it.date.flatMap { d in Day.date(d).map { Int(Date().timeIntervalSince($0) / 86400) } }
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(it.c).font(.body.weight(.semibold))
                                Text("/ " + it.q).font(.caption).foregroundStyle(.secondary)
                                if let d = days, d > 7 { Tag(text: LS("已过期 %@ 天", d), warn: true) }
                                if it.last == nil { Tag(text: LS("无价格"), warn: true) }
                            }
                            if let l = it.last, let d = it.date {
                                Text(LS("最新 %@ · %@", fmtNum(l, l < 10 ? 4 : 2), d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                            }
                        }
                        Spacer()
                        TextField(it.last.map { fmtNum($0, $0 < 10 ? 4 : 2) } ?? "0.00", text: Binding(get: { values[it.id] ?? "" }, set: { values[it.id] = $0 }))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: 130)
                            .focused($focus, equals: it.id)
                    }
                }
            } header: {
                Text(LS("证券与外币"))
            }
            if !lines().isEmpty {
                Section(LS("将写入")) { MonoText(text: lines().joined(separator: "\n")) }
            }
            Section {
                Toggle(LS("每天打开 App 时自动更新"), isOn: $auto)
            } footer: {
                Text(LS("开启后，每天第一次打开 App 时自动获取并写入当天价格（需要联网）。"))
            }
        }
    }

    private func fetch(_ L: Ledger, _ items: [PriceItem]) async {
        fetching = true
        defer { fetching = false }
        let got = await PriceFetch.fetchAll(items, L)
        for (id, v) in got { values[id] = jsNumberString(roundTo(v, v < 10 ? 6 : 4)) }
        let miss = items.filter { got[$0.id] == nil }.map { $0.c }
        fetchNote = miss.isEmpty ? LS("已获取 %@ 项", got.count) : LS("已获取 %@ 项；未找到：%@", got.count, miss.joined(separator: LS("、")))
    }

    private func lines() -> [String] {
        guard let L = store.L else { return [] }
        return Self.items(L).compactMap { it in
            guard let v = evalAmount(values[it.id] ?? ""), v > 0 else { return nil }
            return "\(date) price \(it.c)" + String(repeating: " ", count: max(1, 26 - it.c.count)) + jsNumberString(roundTo(v, 6)) + " " + it.q
        }
    }

    private func save() {
        let ls = lines()
        guard !ls.isEmpty, let ops = store.makeOps(ls.joined(separator: "\n"), single: false) else { return }
        Task { await store.commit(ops, word: LS("已更新 %@ 项价格", ls.count), closing: { dismiss() }) }
    }
}


struct ChartTarget: Identifiable { let id: String }

/// candles for a holding from Yahoo, with the average cost and the buys marked
struct KLineSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let rows: [Holding]
    @State var selected: String
    @AppStorage("ledger.kline.range") private var range = "6mo"
    @State private var candles: [PriceFetch.Candle] = []
    @State private var loading = false
    @State private var error: String?

    private static let ranges: [(String, String, String)] = [("1mo", "1d", "1月"), ("3mo", "1d", "3月"), ("6mo", "1d", "6月"), ("1y", "1wk", "1年"), ("5y", "1mo", "5年")]

    private var row: Holding? { rows.first { $0.id == selected } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if rows.count > 1 {
                        Picker(LS("股票"), selection: $selected) {
                            ForEach(rows) { r in Text(r.c + " · " + acctLabel(r.acct)).tag(r.id) }
                        }
                    }
                    Picker(LS("范围"), selection: $range) {
                        ForEach(Self.ranges, id: \.0) { Text(LS($0.2)).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    if loading { HStack { Spacer(); ProgressView(); Spacer() }.frame(height: 260) }
                    else if let e = error { Text(e).foregroundStyle(.secondary).frame(height: 120) }
                    else if candles.isEmpty { Text(LS("没有数据")).foregroundStyle(.secondary) }
                    else if let r = row { chart(r).frame(height: 300) }
                } footer: {
                    if let r = row, let L = store.L {
                        Text(LS("数据来自 Yahoo Finance（%@），绿涨红跌；虚线为持仓均价 %@，圆点为买入批次。", PriceFetch.symbol(r.c, r.q, L).0, fmtNum(r.avg, 2)))
                    }
                }
                if let last = candles.last, let first = candles.first {
                    Section {
                        LabeledContent(LS("最新收盘"), value: fmtNum(last.close, 2) + " " + (row?.q ?? ""))
                        LabeledContent(LS("区间涨跌"), value: String(format: "%+.2f%%", (last.close - first.open) / first.open * 100))
                        LabeledContent(LS("区间最高 / 最低"), value: fmtNum(candles.map { $0.high }.max() ?? 0, 2) + " / " + fmtNum(candles.map { $0.low }.min() ?? 0, 2))
                    }
                }
            }
            .navigationTitle(row?.c ?? LS("K 线"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(LS("完成")) { dismiss() } } }
            .task(id: selected + range) { await load() }
        }
    }

    private func load() async {
        guard let r = row, let L = store.L else { return }
        let iv = Self.ranges.first { $0.0 == range }?.1 ?? "1d"
        loading = true
        error = nil
        defer { loading = false }
        do {
            candles = try await PriceFetch.candles(PriceFetch.symbol(r.c, r.q, L).0, range: range, interval: iv)
        } catch {
            candles = []
            self.error = LS("获取行情失败：%@", error.localizedDescription)
        }
    }

    private func chart(_ r: Holding) -> some View {
        // green up, red down, like gains and losses everywhere in the app
        let up = Color.gain, down = Color.loss
        let from = candles.first?.date ?? Date()
        let buys = r.lots.compactMap { l -> (Date, Double)? in
            guard let c = l.cost, let ds = c.date, let d = Day.date(ds), d >= from else { return nil }
            return (d, c.number)
        }
        let lo = min(candles.map { $0.low }.min() ?? 0, r.avg), hi = max(candles.map { $0.high }.max() ?? 0, r.avg)
        let pad = (hi - lo) * 0.05
        return Chart {
            ForEach(candles) { c in
                RuleMark(x: .value("d", c.date), yStart: .value("l", c.low), yEnd: .value("h", c.high))
                    .foregroundStyle(c.close >= c.open ? up : down)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                RectangleMark(x: .value("d", c.date), yStart: .value("o", c.open), yEnd: .value("c", c.close == c.open ? c.open + (hi - lo) * 0.002 : c.close), width: .ratio(0.6))
                    .foregroundStyle(c.close >= c.open ? up : down)
            }
            if r.avg > 0 {
                RuleMark(y: .value("avg", r.avg))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            ForEach(Array(buys.enumerated()), id: \.offset) { p in
                PointMark(x: .value("d", p.element.0), y: .value("p", p.element.1)).foregroundStyle(Color.jade).symbolSize(30)
            }
        }
        .chartYScale(domain: (lo - pad)...(hi + pad))
    }
}
