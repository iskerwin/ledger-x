import SwiftUI
import LedgerKit

/// 明细 as a month calendar: each day's spending (darker = more) and income, the month's totals; tap a day for
/// its transactions. It shows what the list would (the same search and account filter).
struct JournalCalendar: View {
    @EnvironmentObject var store: Store
    let L: Ledger
    /// the transactions the list would show, newest first
    let entries: [Entry]
    /// filtered to one account: amounts on that account instead of spending / income
    let account: String?
    @State private var month = Day.ym(Day.today())
    @State private var day: String?

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

    var body: some View {
        let totals = byDay
        let out = totals.values.reduce(0) { $0 + $1.out }, inn = totals.values.reduce(0) { $0 + $1.inn }
        let top = max(1, totals.values.map { $0.out }.max() ?? 1)
        List {
            Section {
                header(out: out, inn: inn)
                grid(totals, top: top)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                        if abs(g.translation.width) > abs(g.translation.height) { step(g.translation.width < 0 ? 1 : -1) }
                    })
            }
            if let d = day {
                let ts = entries.filter { $0.date == d }
                Section {
                    if ts.isEmpty { Text(LS("这一天没有交易")).foregroundStyle(.secondary) }
                    ForEach(ts, id: \.id) { t in
                        NavigationLink(value: TxDest(t)) { TxRow(t: t, account: account) }
                    }
                } header: {
                    HStack {
                        Text(Day.dayLabel(d))
                        Spacer()
                        if let x = totals[d], x.out != 0 { Text(money(x.out)).monospacedDigit().sensitive() }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .onAppear(perform: follow)
        .onChange(of: entries.first?.date) { _, _ in follow() }
    }

    /// after the search changed: show the latest month with something in it, if this one has nothing
    private func follow() {
        guard !entries.contains(where: { $0.date.hasPrefix(month) }), let latest = entries.first else { return }
        month = Day.ym(latest.date)
        day = nil
    }

    private func step(_ k: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            month = Day.addMonth(month, k)
            day = nil
        }
    }

    private func header(out: Double, inn: Double) -> some View {
        VStack(spacing: 8) {
            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Spacer()
                Button {
                    month = Day.ym(Day.today()); day = Day.today()
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
        let picked = day == d
        let future = d > Day.today()
        return Button { day = picked ? nil : d } label: {
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
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(picked ? Color.jade : .clear, lineWidth: 2))
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
