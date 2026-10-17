import SwiftUI
import Charts
import LedgerKit

/// 明细's month calendar, opened above the list: each day's spending (darker = more) and income, the month's totals;
/// tap a day for its sheet. It counts what the list shows (the same search and account filter).
struct JournalCalendar: View {
    @EnvironmentObject var store: Store
    let L: Ledger
    /// the transactions the list would show, newest first
    let entries: [Entry]
    /// filtered to one account: amounts on that account instead of spending / income
    let account: String?
    /// the day opened (its sheet), outlined in the grid
    let picked: String?
    let pick: (String) -> Void
    @State private var month = Day.ym(Day.today())

    struct DayTotal { var out = 0.0; var inn = 0.0; var n = 0 }

    /// spending in the theme colour (the cell's wash too, deeper on bigger days); income in the app's gain colour with a
    /// plus sign; the day number plain, so the three never look alike
    static var spend: Color { Color.jade }
    static var earn: Color { Color.gain }

    private var byDay: [String: DayTotal] {
        var m: [String: DayTotal] = [:]
        let prefix = month
        for t in entries where t.date.hasPrefix(prefix) {
            var d = m[t.date] ?? DayTotal()
            d.n += 1
            // the same reading as the overview: transfers, advances and others' AA parts aren't spending
            let c = classify(t, L)
            switch c.kind {
            case .expense, .refund: d.out -= c.amount
            case .income: d.inn += c.amount
            default: break
            }
            m[t.date] = d
        }
        return m
    }

    /// the month: its totals, then the grid (swiped sideways to change the month); a part of the journal's list
    var body: some View {
        let totals = byDay
        let out = totals.values.reduce(0) { $0 + $1.out }, inn = totals.values.reduce(0) { $0 + $1.inn }
        let top = max(1, totals.values.map { $0.out }.max() ?? 1)
        VStack(spacing: 8) {
            header(out: out, inn: inn)
            grid(totals, top: top)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                    if abs(g.translation.width) > abs(g.translation.height) { step(g.translation.width < 0 ? 1 : -1) }
                })
        }
        .onAppear(perform: follow)
        .onChange(of: entries.first?.date) { _, _ in follow() }
    }

    /// after the search changed: show the latest month with something in it, if this one has nothing
    private func follow() {
        guard !entries.contains(where: { $0.date.hasPrefix(month) }), let latest = entries.first else { return }
        month = Day.ym(latest.date)
    }

    private func step(_ k: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            month = Day.addMonth(month, k)
        }
    }

    private func header(out: Double, inn: Double) -> some View {
        VStack(spacing: 8) {
            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Spacer()
                Button {
                    month = Day.ym(Day.today())
                } label: { Text(Day.monthLabel(month)).font(.headline).foregroundStyle(.primary) }
                .buttonStyle(.borderless)
                Spacer()
                Button { step(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                    .disabled(month >= Day.ym(Day.today()))
            }
            HStack {
                Figure(label: LS("支出"), value: money(out, L.base, 0), color: Self.spend)
                Spacer()
                Figure(label: LS("收入"), value: money(inn, L.base, 0), color: Self.earn)
                Spacer()
                Figure(label: LS("结余"), value: money(inn - out, L.base, 0), color: inn - out < 0 ? Color.loss : Color.primary, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }

    /// weekday names starting on the locale's first day of the week
    private var weekdays: [String] {
        let names = KitLocale.chinese ? Array("日一二三四五六").map(String.init) : ["S", "M", "T", "W", "T", "F", "S"]
        let first = Calendar.current.firstWeekday - 1
        return (0..<7).map { names[(first + $0) % 7] }
    }

    private func grid(_ totals: [String: DayTotal], top: Double) -> some View {
        let first = month + "-01"
        let count = Int(Day.monthEnd(month).suffix(2)) ?? 30
        let wd = Day.date(first).map { Day.calendar.component(.weekday, from: $0) } ?? 1
        let lead = (wd - Calendar.current.firstWeekday + 7) % 7
        let cells: [String?] = Array(repeating: nil, count: lead) + (1...count).map { month + String(format: "-%02d", $0) }
        let today = Day.today()
        // a line for income only in a month that has some, so the spending sits right under the day
        let hasIncome = cells.contains { d in d.map { (totals[$0]?.inn ?? 0) > 0.005 } ?? false }
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, w in
                    Text(w).font(.caption2.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            // weeks as plain rows of square cells (a lazy grid inside a List row can be measured too short and
            // clip everything under the day number): as short as the width allows, leaving room for the list below
            let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
            ForEach(weeks.indices, id: \.self) { w in
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { i in
                        if i < weeks[w].count, let d = weeks[w][i] {
                            cell(d, totals[d], top: top, today: d == today, incomeRow: hasIncome)
                        } else {
                            Color.clear.frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }
            legend
        }
    }

    /// what the colours mean, under the grid
    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(Self.spend.opacity(0.35)).frame(width: 12, height: 12)
                Text(LS("支出（越深越多）"))
            }
            HStack(spacing: 4) {
                Text("+").fontWeight(.bold).foregroundStyle(Self.earn)
                Text(LS("收入"))
            }
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private func cell(_ d: String, _ x: DayTotal?, top: Double, today: Bool, incomeRow: Bool) -> some View {
        let out = x?.out ?? 0, inn = x?.inn ?? 0
        // a wash of the theme colour, deeper on the bigger days, light enough for the numbers on it
        let shade = out > 0.005 ? 0.08 + 0.22 * min(1, out / top) : 0
        let chosen = picked == d
        let future = d > Day.today()
        return Button { pick(d) } label: {
            // the day and its amounts as one block in the middle of the cell (today's day in a theme-coloured circle);
            // every cell has the same lines, so the days line up across a week and the amounts across a row
            VStack(spacing: 0) {
                Text(String(Int(d.suffix(2)) ?? 0))
                    .font(.system(size: 12.5, weight: today ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(today ? Color.onJade : future ? Color.secondary.opacity(0.45) : Color.primary)
                    .frame(width: 20, height: 20)
                    .background(today ? Color.jade : Color.clear, in: Circle())
                Group {
                    Text(out > 0.005 ? short(out) : " ")
                        .font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(Self.spend)
                    if incomeRow {
                        Text(inn > 0.005 ? "+" + short(inn) : " ")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit()).foregroundStyle(Self.earn)
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                .sensitive()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(Self.spend.opacity(shade), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(chosen ? Color.jade : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Day.dayLabel(d) + (out > 0.005 ? " " + LS("支出 ") + money(out) : "") + (inn > 0.005 ? " " + LS("收入 ") + money(inn) : ""))
    }

    /// 86, 1.2k, 12k (hidden like every amount when 隐藏金额 is on)
    private func short(_ v: Double) -> String {
        if v < 1000 { return masked(String(Int(v.rounded()))) }
        if v < 10000 { return masked(String(format: "%.1fk", v / 1000)) }
        return masked(String(format: "%.0fk", v / 1000))
    }
}

/// a day's totals beside its date, each named: 支出 ¥918.64, or 收入 ¥… · 支出 ¥… on a day with both
struct DayTotalsText: View {
    let out: Double
    let inn: Double

    var body: some View {
        let parts = [inn != 0 ? LS("收入 ") + money(inn) : nil, out != 0 ? LS("支出 ") + money(out) : nil].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).sensitive()
        }
    }
}

struct CalendarDay: Identifiable { let day: String; var id: String { day } }

/// a day picked on the journal's calendar: its income, spending and net, a bar for each currency, then its
/// transactions (and the documents of that day); half the screen, pulled up to all of it
struct CalendarDaySheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let L: Ledger
    let day: String
    /// the day's transactions, as filtered in the journal
    let entries: [Entry]
    let account: String?
    let documents: [Entry]
    /// a transaction tapped: the sheet closes and the journal opens it
    let open: (Entry) -> Void
    @State private var viewing: DocItem?

    var body: some View {
        var out = 0.0, inn = 0.0
        for t in entries {
            let c = classify(t, L)
            switch c.kind {
            case .expense, .refund: out -= c.amount
            case .income: inn += c.amount
            default: break
            }
        }
        let flows = flowsByCurrency(entries)
        return NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Figure(label: LS("收入"), value: money(inn, L.base), color: .gain)
                            Spacer()
                            Figure(label: LS("支出"), value: money(out, L.base), color: .loss)
                            Spacer()
                            Figure(label: LS("纯利"), value: money(inn - out, L.base), color: inn - out < 0 ? Color.loss : Color.primary, alignment: .trailing)
                        }
                        .sensitive()
                        if !flows.isEmpty { FlowBars(flows: flows) }
                    }
                    .padding(.vertical, 4)
                } footer: {
                    if flows.count > 1 { Text(LS("上面的合计折算为 %@；条形图按原币种。", L.base)) }
                }
                Section(LS("交易 · %@ 笔", entries.count)) {
                    if entries.isEmpty { Text(LS("这一天没有交易")).foregroundStyle(.secondary) }
                    ForEach(entries, id: \.id) { t in
                        Button { open(t) } label: {
                            HStack {
                                TxRow(t: t, account: account)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !documents.isEmpty {
                    Section(LS("票据")) {
                        ForEach(documents, id: \.id) { d in
                            let path = documentRepoPath(d)
                            Button { if let p = path { viewing = DocItem(path: p) } } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text").foregroundStyle(Color.jade)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(((d.path ?? "") as NSString).lastPathComponent).lineLimit(1)
                                        if let a = d.account { Text(acctDisplay(a)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                }
                            }
                            .disabled(path == nil)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Day.dayLabel(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(LS("完成")) { dismiss() } } }
            .sheet(item: $viewing) { DocumentViewer(path: $0.path) }
        }
    }
}

/// income and spending side by side for each currency, the net as a thin line over them, amounts at the ends
struct FlowBars: View {
    let flows: [CurrencyFlow]

    var body: some View {
        let inc = LS("收入"), exp = LS("支出"), net = LS("纯利")
        Chart {
            ForEach(flows, id: \.currency) { f in
                BarMark(x: .value("金额", f.income), y: .value("币种", f.currency), height: .ratio(0.32))
                    .foregroundStyle(by: .value("类型", inc))
                    .position(by: .value("类型", inc), axis: .vertical)
                    .annotation(position: .trailing) { label(f.income) }
                BarMark(x: .value("金额", f.expenses), y: .value("币种", f.currency), height: .ratio(0.32))
                    .foregroundStyle(by: .value("类型", exp))
                    .position(by: .value("类型", exp), axis: .vertical)
                    .annotation(position: .trailing) { label(f.expenses) }
                BarMark(x: .value("金额", f.net), y: .value("币种", f.currency), height: .fixed(3))
                    .foregroundStyle(by: .value("类型", net))
            }
            RuleMark(x: .value("零", 0)).foregroundStyle(Color.secondary.opacity(0.5))
        }
        .chartForegroundStyleScale([inc: Color.gain, exp: Color.loss, net: Color.jade])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel() } }
        .frame(height: CGFloat(flows.count) * 64 + 44)
        .sensitive()
    }

    private func label(_ v: Double) -> some View {
        Text(abs(v) < 0.005 ? "" : masked(fmtNum(v))).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
    }
}
