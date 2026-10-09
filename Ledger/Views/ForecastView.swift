import SwiftUI
import Charts
import LedgerKit

struct ForecastDest: Hashable {}

extension Store {
    /// the forecast for the current ledger, computed once per rebuild
    func forecastCached(days: Int, daily: Bool) -> Forecast? {
        guard let L = L else { return nil }
        let key = "\(version)|\(days)|\(daily)|\(Day.today())"
        if let f = Store.forecastCache[key] { return f }
        let f = forecast(L, days: days, includeDaily: daily)
        if Store.forecastCache.count > 8 { Store.forecastCache.removeAll() }
        Store.forecastCache[key] = f
        return f
    }
    static var forecastCache: [String: Forecast] = [:]
}

enum ForecastPrefs {
    static let dailyKey = "ledger.forecast.daily"
    static let daysKey = "ledger.forecast.days"
}

struct ForecastOverviewSection: View {
    @EnvironmentObject var store: Store
    let L: Ledger
    @AppStorage(ForecastPrefs.dailyKey) private var daily = true

    var body: some View {
        if let f = store.forecastCached(days: 30, daily: daily), !f.accounts.isEmpty {
            let low = f.lowest
            let warn = low.value < 0
            Section {
                NavigationLink(value: ForecastDest()) {
                    HStack(spacing: 12) {
                        IconBadge(symbol: "chart.line.uptrend.xyaxis", color: warn ? .red : .teal, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LS("30 天后约 %@", money(f.end, f.currency, 0))).sensitive()
                            Text(warn ? LS("%@ 可能余额不足（%@）", f.firstBelow(0)?.date ?? low.date, money(low.value, f.currency, 0))
                                      : LS("最低 %@（%@）", money(low.value, f.currency, 0), low.date))
                                .font(.caption).foregroundStyle(warn ? Color.loss : Color.secondary).sensitive()
                        }
                        Spacer()
                        Sparkline(points: f.points, warn: warn).frame(width: 70, height: 28)
                    }
                }
            } header: {
                Text(LS("现金流预测"))
            }
        }
    }
}

struct Sparkline: View {
    let points: [ForecastPoint]
    var warn = false
    var body: some View {
        Chart(points) { p in
            LineMark(x: .value("d", p.date), y: .value("v", p.value))
                .foregroundStyle(warn ? Color.loss : Color.jade)
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .sensitive()
    }
}

struct ForecastView: View {
    @EnvironmentObject var store: Store
    @AppStorage(ForecastPrefs.dailyKey) private var daily = true
    @AppStorage(ForecastPrefs.daysKey) private var days = 90

    var body: some View {
        Group {
            if let f = store.forecastCached(days: days, daily: daily) { content(f) } else { ProgressView() }
        }
        .navigationTitle(LS("现金流预测"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ f: Forecast) -> some View {
        let low = f.lowest
        let below = f.firstBelow(0)
        return List {
            Section {
                Picker(LS("周期"), selection: $days) {
                    Text(LS("30 天")).tag(30)
                    Text(LS("60 天")).tag(60)
                    Text(LS("90 天")).tag(90)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Figure(label: LS("今天"), value: money(f.start, f.currency, 0))
                            Spacer()
                            Figure(label: LS("%@ 天后", days), value: money(f.end, f.currency, 0), color: f.end < 0 ? .loss : .primary)
                            Spacer()
                            Figure(label: LS("最低 · %@", low.date), value: money(low.value, f.currency, 0), color: low.value < 0 ? .loss : .primary, alignment: .trailing)
                        }
                        chart(f)
                        if let b = below {
                            Label(LS("预计 %@ 余额降到 0 以下，请提前安排资金", b.date), systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(Color.loss)
                        }
                    }
                }
                .cardRow()
            }
            Section {
                if f.events.isEmpty { Text(LS("没有发现周期性收支")).foregroundStyle(.secondary) }
                ForEach(f.events) { e in
                    HStack(spacing: 12) {
                        IconBadge(symbol: symbol(e.kind), color: color(e.kind), size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).lineLimit(1)
                            Text(e.date + " · " + kindName(e.kind)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text((e.amount > 0 ? "+" : "") + money(e.amount, f.currency))
                            .monospacedDigit().foregroundStyle(e.amount > 0 ? Color.gain : Color.primary).sensitive()
                    }
                }
            } header: {
                Text(LS("预计收支"))
            }
            Section {
                Toggle(LS("计入日常支出"), isOn: $daily)
                if daily { LabeledContent(LS("日均日常支出"), value: money(f.dailySpend, f.currency)).sensitive() }
                DisclosureGroup(LS("计入的账户（%@）", f.accounts.count)) {
                    ForEach(f.accounts, id: \.self) { Text(acctDisplay($0)).font(.subheadline) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LS("按近一年的记录推算：工资等周期性收入、房租等固定支出、订阅、信用卡账单（按账单日和还款日）；日常支出取近 90 天的日均值。只是估算，实际以账本为准。"))
                    if !f.cardsWithoutCycle.isEmpty {
                        Text(LS("未设置账单日的信用卡未计入：%@", f.cardsWithoutCycle.map(acctLabel).joined(separator: LS("、"))))
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
    }

    private func chart(_ f: Forecast) -> some View {
        let low = f.lowest
        let hi = f.points.map { $0.value }.max() ?? 0
        // zoom to the data; keep 0 in view only when the balance gets near or below it
        let span = max(hi - low.value, abs(hi) * 0.05, 1)
        let minV = low.value < span ? min(0, low.value) - span * 0.1 : low.value - span * 0.25
        let maxV = hi + span * 0.1
        return Chart {
            ForEach(f.points) { p in
                AreaMark(x: .value(LS("日期"), Day.date(p.date) ?? Date(), unit: .day), yStart: .value("0", minV), yEnd: .value(LS("余额"), p.value))
                    .foregroundStyle(LinearGradient(colors: [Color.jade.opacity(0.25), Color.jade.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.linear)
                LineMark(x: .value(LS("日期"), Day.date(p.date) ?? Date(), unit: .day), y: .value(LS("余额"), p.value))
                    .foregroundStyle(Color.jade)
                    .interpolationMethod(.linear)
            }
            if low.value < 0 {
                RuleMark(y: .value("0", 0)).foregroundStyle(Color.loss.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            PointMark(x: .value(LS("日期"), Day.date(low.date) ?? Date(), unit: .day), y: .value(LS("余额"), low.value))
                .foregroundStyle(low.value < 0 ? Color.loss : Color.warn)
                .symbolSize(40)
        }
        .chartYScale(domain: minV...maxV)
        .chartYAxis { AxisMarks(position: .trailing) }
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: days > 30 ? 30 : 7)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.defaultDigits).day()) } }
        .frame(height: 190)
        .sensitive()
    }

    private func symbol(_ k: ForecastEvent.Kind) -> String {
        switch k {
        case .income: return "arrow.down.circle.fill"
        case .recurring: return "arrow.triangle.2.circlepath"
        case .subscription: return "repeat"
        case .card: return "creditcard.fill"
        }
    }

    private func color(_ k: ForecastEvent.Kind) -> Color {
        switch k {
        case .income: return .green
        case .recurring: return .blue
        case .subscription: return .purple
        case .card: return .orange
        }
    }

    private func kindName(_ k: ForecastEvent.Kind) -> String {
        switch k {
        case .income: return LS("周期收入")
        case .recurring: return LS("固定支出")
        case .subscription: return LS("订阅")
        case .card: return LS("信用卡账单")
        }
    }
}
