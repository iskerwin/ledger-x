import SwiftUI
import Charts
import LedgerKit

/// 账户 → 投资持仓, as the phone's 持仓: everything held at cost valued at its latest price. The summary on top, the
/// holdings by the currency they are priced in and sorted, the picked one's buys and K 线 under them, then 投资收入.
/// 更新价格 writes price lines into the folder (`prepareFolderPrices`).
struct HoldingsPane: View {
    /// what the 账户 list selects for this pane rather than an account
    static let key = "\u{1}holdings"

    let ledger: Ledger
    let folder: URL
    /// 账户明细: the holding's account picked in the list
    let openAccount: (String) -> Void
    @State private var market: String?
    @AppStorage("holdingsSort") private var sort = "value"
    @State private var picked: String?
    @State private var pricing = false

    var body: some View {
        let all = holdings(ledger)
        let markets = Array(Set(all.map(\.q))).sorted { a, b in
            let order = ["USD", "HKD", "CNY"]
            return (order.firstIndex(of: a) ?? 9, a) < (order.firstIndex(of: b) ?? 9, b)
        }
        let rows = sorted(all.filter { market == nil || $0.q == market })
        let year = String(Day.today().prefix(4))
        let income = investIncome(ledger, year: year)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summary(all, income)
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        CardTitle(title: LS("持仓明细")) {
                            HStack(spacing: 12) {
                                if markets.count > 1 {
                                    Picker(LS("市场"), selection: $market) {
                                        Text(LS("全部")).tag(String?.none)
                                        ForEach(markets, id: \.self) { Text(marketName($0)).tag(String?.some($0)) }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .fixedSize()
                                }
                                Picker(LS("排序"), selection: $sort) {
                                    Text(LS("市值")).tag("value")
                                    Text(LS("盈亏")).tag("pnl")
                                    Text(LS("名称")).tag("name")
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                        if rows.isEmpty { Text(LS("暂无以成本计价的持仓")).foregroundStyle(.secondary).padding(.vertical, 6) }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                            if i > 0 { Divider().padding(.leading, 52) }
                            row(r)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if let r = rows.first(where: { $0.id == picked }) {
                    SideBySide(weights: [1, 1.4]) {
                        lots(r)
                        KLineCard(ledger: ledger, holding: r).id(r.id)
                    }
                }
                if !income.isEmpty { incomeCard(income, year) }
            }
            .padding(20)
            .pageWidth()
        }
        .background(Color.page)
        .toolbar {
            ToolbarItem {
                Button(LS("更新价格"), systemImage: "arrow.clockwise") { pricing = true }
            }
        }
        .sheet(isPresented: $pricing) { PriceSheet(ledger: ledger, folder: folder) }
        .onAppear { if picked == nil { picked = rows.first?.id } }
    }

    private func marketName(_ q: String) -> String {
        switch q {
        case "USD": return LS("美元")
        case "HKD": return LS("港元")
        case "CNY": return LS("人民币")
        default: return q
        }
    }

    private func pct(_ r: Holding) -> Double { r.cost != 0 ? (r.pnl ?? 0) / r.cost : 0 }

    private func sorted(_ rows: [Holding]) -> [Holding] {
        switch sort {
        case "pnl": return rows.sorted { pct($0) > pct($1) }
        case "name": return rows.sorted { $0.c != $1.c ? $0.c < $1.c : $0.acct < $1.acct }
        default: return rows.sorted { inBase(ledger, $0.value ?? $0.cost, $0.q) > inBase(ledger, $1.value ?? $1.cost, $1.q) }
        }
    }

    /// 总市值, 持仓成本 · 浮动盈亏 · 收益率, the total with income, when the prices are from
    private func summary(_ rows: [Holding], _ income: [(account: String, year: Double, all: Double)]) -> some View {
        let value = rows.reduce(0.0) { $0 + inBase(ledger, $1.value ?? $1.cost, $1.q) }
        let cost = rows.reduce(0.0) { $0 + inBase(ledger, $1.cost, $1.q) }
        let earned = income.reduce(0.0) { $0 + $1.all }
        let pxDate = rows.compactMap { $0.px?.date }.max()
        let up = value >= cost
        return Card(summary: true) {
            VStack(alignment: .leading, spacing: 12) {
                Headline(label: LS("总市值 · %@", ledger.base), value: money(value, ledger.base))
                SummaryFigures(items: [
                    (LS("持仓成本"), money(cost, ledger.base, 0), .primary),
                    (LS("浮动盈亏"), signedMoney(value - cost, ledger.base), up ? .gain : .loss),
                    (LS("收益率"), cost != 0 ? String(format: "%@%.1f%%", up ? "+" : "", (value - cost) / cost * 100) : "—", cost != 0 ? (up ? .gain : .loss) : .primary),
                ])
                if abs(earned) > 0.005 {
                    Text(LS("累计收益 %@（浮动盈亏 + 已实现收益、股息、利息）", signedMoney(value - cost + earned, ledger.base)))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                if let d = pxDate {
                    HStack(spacing: 6) {
                        Circle().fill(Day.shift(d, 3) >= Day.today() ? Color.gain : Color.warn).frame(width: 7, height: 7)
                        Text(LS("价格更新于 %@", d)).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ r: Holding) -> some View {
        let on = picked == r.id
        return Button { picked = r.id } label: {
            HStack(spacing: 10) {
                Text(String(r.c.prefix(r.c.count > 4 ? 2 : 4)))
                    .font(.system(size: r.c.count > 3 ? 10 : 12, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(on ? Color.jade : .white)
                    .frame(width: 32, height: 32)
                    .background(on ? Color.white : Color.jade, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.c).fontWeight(.medium).lineLimit(1)
                    Text(accountTitle(ledger, r.acct) + " · " + marketName(r.q) + " · "
                         + LS("持仓 %@ 份 · 均价 %@ · 现价 %@", fmtNum(r.units, 4), fmtNum(r.avg, 2), r.px.map { fmtNum($0.number, 2) } ?? "—"))
                        .font(.caption).foregroundStyle(on ? Color.white.opacity(0.8) : Color.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(money(r.value ?? r.cost, r.q)).monospacedDigit().lineLimit(1)
                    if let p = r.pnl {
                        Text(signedMoney(p, r.q) + (r.cost != 0 ? String(format: "  %@%.1f%%", p >= 0 ? "+" : "", p / r.cost * 100) : ""))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(on ? Color.white : p >= 0 ? Color.gain : Color.loss)
                    } else {
                        Text(LS("无价格")).font(.caption).foregroundStyle(on ? Color.white : Color.warn)
                    }
                }
            }
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(on ? Color.jade : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// 买入批次: each lot's day, units × cost and what it has gained since
    private func lots(_ r: Holding) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(title: LS("买入批次")) {
                    Button(LS("账户明细")) { openAccount(r.acct) }.buttonStyle(.link)
                }
                ForEach(Array(r.lots.enumerated()), id: \.offset) { i, l in
                    if i > 0 { Divider() }
                    let c = l.cost
                    let gain = r.px.map { l.units * ($0.number - (c?.number ?? 0)) }
                    HStack(spacing: 8) {
                        Text((c?.date ?? "") + (c?.label.map { " · " + $0 } ?? "")).monospacedDigit().foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("\(fmtNum(l.units, 4)) × \(fmtNum(c?.number ?? 0, 4)) \(c?.currency ?? "")").monospacedDigit().lineLimit(1)
                        if let g = gain {
                            Text(signedMoney(g, r.q)).monospacedDigit().foregroundStyle(g >= 0 ? Color.gain : Color.loss)
                                .frame(minWidth: 90, alignment: .trailing)
                        }
                    }
                    .font(.callout)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private static var incomeNames: [String: String] { ["Gain": LS("已实现收益"), "Dividend": LS("股息"), "Interest": LS("利息"), "StockAward": LS("股票奖励"), "Coupon": LS("票息")] }

    private func incomeCard(_ rows: [(account: String, year: Double, all: Double)], _ year: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardTitle(LS("投资收入 · %@ 年", year))
                ForEach(rows, id: \.account) { row in
                    let leaf = row.account.components(separatedBy: ":").last ?? row.account
                    FigureRow(label: Self.incomeNames[leaf] ?? accountTitle(ledger, row.account),
                              caption: LS("累计 ") + money(row.all, ledger.base), value: money(row.year, ledger.base))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// a holding's candles from Yahoo, with its average cost dashed and its buys marked, as the phone's K 线
private struct KLineCard: View {
    let ledger: Ledger
    let holding: Holding
    @AppStorage("klineRange") private var range = "6mo"
    @State private var candles: [PriceFetch.Candle] = []
    @State private var loading = false
    @State private var error: String?

    private static let ranges: [(String, String, String)] = [("1mo", "1d", "1月"), ("3mo", "1d", "3月"), ("6mo", "1d", "6月"), ("1y", "1wk", "1年"), ("5y", "1mo", "5年")]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(title: LS("K 线走势")) {
                    Picker(LS("范围"), selection: $range) {
                        ForEach(Self.ranges, id: \.0) { Text(LS($0.2)).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                // one height whatever is in it; a new range keeps the last chart under the spinner until it loads
                ZStack {
                    if let e = error, !loading { Text(e).foregroundStyle(.secondary) }
                    else if candles.isEmpty { if !loading { Text(LS("没有数据")).foregroundStyle(.secondary) } }
                    else { chart.opacity(loading ? 0.3 : 1) }
                    if loading { ProgressView() }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                Text(LS("数据来自 Yahoo Finance（%@），绿涨红跌；虚线为持仓均价 %@，圆点为买入批次。", PriceFetch.symbol(holding.c, holding.q, ledger).0, fmtNum(holding.avg, 2)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: range) { await load() }
    }

    private func load() async {
        let interval = Self.ranges.first { $0.0 == range }?.1 ?? "1d"
        loading = true
        error = nil
        do {
            let got = try await PriceFetch.candles(PriceFetch.symbol(holding.c, holding.q, ledger).0, range: range, interval: interval)
            // a newer range took over: its own load answers
            guard !Task.isCancelled else { return }
            candles = got
        } catch {
            guard !Task.isCancelled else { return }
            candles = []
            self.error = LS("获取行情失败：%@", error.localizedDescription)
        }
        loading = false
    }

    private var chart: some View {
        let from = candles.first?.date ?? Date()
        let buys = holding.lots.compactMap { l -> (Date, Double)? in
            guard let c = l.cost, let ds = c.date, let d = Day.date(ds), d >= from else { return nil }
            return (d, c.number)
        }
        let lo = min(candles.map(\.low).min() ?? 0, holding.avg), hi = max(candles.map(\.high).max() ?? 0, holding.avg)
        let pad = (hi - lo) * 0.05
        return Chart {
            ForEach(candles) { c in
                RuleMark(x: .value("d", c.date), yStart: .value("l", c.low), yEnd: .value("h", c.high))
                    .foregroundStyle(c.close >= c.open ? Color.gain : Color.loss)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                RectangleMark(x: .value("d", c.date), yStart: .value("o", c.open), yEnd: .value("c", c.close == c.open ? c.open + (hi - lo) * 0.002 : c.close), width: .ratio(0.6))
                    .foregroundStyle(c.close >= c.open ? Color.gain : Color.loss)
                    .accessibilityLabel(c.date.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue(LS("开 %@，收 %@，%@", fmtNum(c.open, 2), fmtNum(c.close, 2), c.close >= c.open ? LS("涨") : LS("跌")))
            }
            if holding.avg > 0 {
                RuleMark(y: .value("avg", holding.avg))
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

/// 更新价格: a new price for each security and foreign currency held, fetched from Yahoo or typed in, written as
/// one price line each
private struct PriceSheet: View {
    let ledger: Ledger
    let folder: URL
    @Environment(\.dismiss) private var dismiss
    @State private var day = Day.today()
    @State private var values: [String: String] = [:]
    @State private var fetching = false
    @State private var note = ""
    @State private var message = ""
    @State private var saving = false

    var body: some View {
        let items = priceItems(ledger)
        let lines = typedPriceLines(items, values, date: day)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                DateRow(title: LS("价格日期"), day: $day, latest: Date())
                    .padding(.vertical, 8)
                Divider()
                HStack {
                    Button(LS("从 Yahoo Finance 获取最新价格"), systemImage: "arrow.down.circle") { Task { await fetch(items) } }
                        .disabled(fetching || items.isEmpty)
                    if fetching { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 12)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding([.horizontal, .top], 20)
            ScrollView {
                VStack(spacing: 0) {
                    if items.isEmpty { Text(LS("没有需要报价的证券或外币")).foregroundStyle(.secondary).padding(.vertical, 8) }
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                        if i > 0 { Divider() }
                        itemRow(it)
                    }
                }
                .padding(.horizontal, 12)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding([.horizontal, .top], 20)
                if !lines.isEmpty {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding([.horizontal, .top], 20)
                }
            }
            .frame(minHeight: 160, maxHeight: 420)
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32)
            HStack {
                Spacer()
                Button(LS("取消"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(LS("写入")) { save(lines) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || lines.isEmpty)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 520)
        .background(Color.page)
    }

    private func itemRow(_ it: PriceItem) -> some View {
        let days = it.date.flatMap { d in Day.date(d).map { Int(Date().timeIntervalSince($0) / 86400) } }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(it.c).fontWeight(.semibold)
                    Text("/ " + it.q).font(.caption).foregroundStyle(.secondary)
                    if let d = days, d > 7 { Text(LS("已过期 %@ 天", d)).font(.caption).foregroundStyle(Color.warn) }
                    if it.last == nil { Text(LS("无价格")).font(.caption).foregroundStyle(Color.warn) }
                }
                if let l = it.last, let d = it.date {
                    Text(LS("最新 %@ · %@", fmtNum(l, l < 10 ? 4 : 2), d)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Spacer()
            TextField(it.c, text: Binding(get: { values[it.id] ?? "" }, set: { values[it.id] = $0 }),
                      prompt: Text(it.last.map { fmtNum($0, $0 < 10 ? 4 : 2) } ?? "0.00"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 140)
        }
        .padding(.vertical, 8)
    }

    private func fetch(_ items: [PriceItem]) async {
        fetching = true
        defer { fetching = false }
        let got = await PriceFetch.fetchAll(items, ledger)
        for (id, v) in got { values[id] = jsNumberString(roundTo(v, v < 10 ? 6 : 4)) }
        let miss = items.filter { got[$0.id] == nil }.map(\.c)
        note = miss.isEmpty ? LS("已获取 %@ 项", got.count) : LS("已获取 %@ 项；未找到：%@", got.count, miss.joined(separator: LS("、")))
    }

    private func save(_ lines: [String]) {
        saving = true
        message = ""
        let folder = folder
        Task { @MainActor in
            let result = await Task.detached { prepareFolderPrices(lines, folder: folder) }.value
            saving = false
            do {
                try SaveUndo.commit(try result.get(), folder: folder, name: LS("更新价格"))
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
