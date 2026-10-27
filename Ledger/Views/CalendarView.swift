import SwiftUI
import Charts
import LedgerKit

/// Shared month grid with the journal’s existing filtered daily totals and a separately selected day.
struct JournalCalendar: View {
    @Environment(Store.self) var store
    let L: Ledger
    /// the transactions the list would show, newest first
    let entries: [Entry]
    /// filtered to one account: amounts on that account instead of spending / income
    let account: String?
    let pick: (String) -> Void
    @State private var month = Day.ym(Day.today())
    @State private var selectedDay: String?
    @State private var initialized = false
    @AppStorage("journal.glassCalendar") private var glassCalendar = true
    @ScaledMetric(relativeTo: .caption) private var summaryHeight: CGFloat = 74

    struct DayTotal { var out = 0.0; var inn = 0.0; var n = 0 }

    /// spending in the theme colour, income in the app's gain colour, everywhere on this calendar
    static var spend: Color { Color.loss }
    static var earn: Color { Color.gain }
    /// a day with entries that are neither (transfers, advances, reimbursements): not shown as empty
    static var other: Color { Color.secondary.opacity(0.6) }

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
        var marks: [String: [Color]] = [:]
        for (d, x) in totals {
            let dots = [x.out > 0.005 ? Self.spend : nil, x.inn > 0.005 ? Self.earn : nil].compactMap { $0 }
            if !dots.isEmpty { marks[d] = dots } else if x.n > 0 { marks[d] = [Self.other] }
        }
        return Group {
            if glassCalendar {
                let maxOut = totals.values.map(\.out).max() ?? 0
                let maxIn = totals.values.map(\.inn).max() ?? 0
                let levels = totals.mapValues {
                    DayMark(out: markLevel(amount: $0.out, max: maxOut), inn: markLevel(amount: $0.inn, max: maxIn), other: $0.n > 0)
                }
                GlassMonthCalendar(marks: levels, month: $month, last: Day.today(), describe: { describe($0, totals) }, selection: $selectedDay, showsToday: true, pick: pick) {
                    figures(out: out, inn: inn)
                } summary: {
                    summary(totals)
                } footer: {
                    EmptyView()
                }
            } else {
                legacy(totals, marks: marks, out: out, inn: inn)
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            follow()
            selectDefault(byDay)
        }
        .onChange(of: entries.first?.date) { _, _ in follow(); selectDefault(byDay) }
        .onChange(of: month) { _, _ in selectDefault(byDay) }
    }

    private func describe(_ day: String, _ totals: [String: DayTotal]) -> String? {
        totals[day].map { x in
            let parts = [x.out != 0 ? LS("支出 ") + money(x.out) : nil, x.inn != 0 ? LS("收入 ") + money(x.inn) : nil].compactMap { $0 }
            return parts.isEmpty ? LS("%@ 笔其他交易", x.n) : parts.joined(separator: " ")
        }
    }

    private func selectDefault(_ totals: [String: DayTotal]) {
        selectedDay = totals.isEmpty ? nil : month == Day.ym(Day.today()) ? Day.today() : totals.keys.max()
    }

    private func figures(out: Double, inn: Double) -> some View {
        FigureRow(items: [
            .init(label: LS("支出"), value: money(out, L.base, 0), color: Self.spend),
            .init(label: LS("收入"), value: money(inn, L.base, 0), color: Self.earn),
            .init(label: LS("结余"), value: money(inn - out, L.base, 0), color: inn - out < 0 ? Color.loss : Color.primary),
        ], alignment: .center)
        .padding(.vertical, AppSpacing.detail)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.figures")
        .contentTransition(.numericText())
        .animation(AppMotion.quick, value: month)
    }

    private func summary(_ totals: [String: DayTotal]) -> some View {
        HStack(spacing: AppSpacing.icon) {
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                if let d = selectedDay {
                    Text(summaryDate(d)).fontWeight(.semibold)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .accessibilityIdentifier("calendar.summary.date")
                    HStack(spacing: AppSpacing.detail) {
                        DayTotalsText(out: totals[d]?.out ?? 0, inn: totals[d]?.inn ?? 0)
                        Text(LS("· %@ 笔", totals[d]?.n ?? 0)).monospacedDigit()
                    }
                } else {
                    Text(LS("本月暂无记录"))
                }
            }
            .lineLimit(2)
            Spacer(minLength: 0)
            Button { if let d = selectedDay { pick(d) } } label: {
                HStack(spacing: AppSpacing.detail) {
                    Text(LS("查看当天明细"))
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                }
                .lineLimit(2).minimumScaleFactor(0.6)
            }
            .foregroundStyle(Color.jadeInk).buttonStyle(.plain)
            .opacity(selectedDay == nil ? 0 : 1).disabled(selectedDay == nil)
            .accessibilityHidden(selectedDay == nil)
            .accessibilityIdentifier("calendar.openDay")
        }
        .font(.caption)
        .frame(height: summaryHeight)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.summary")
    }

    private func summaryDate(_ day: String) -> String {
        guard let date = Day.date(day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.timeZone = Day.calendar.timeZone
        formatter.dateFormat = KitLocale.chinese ? "d日 · EEE" : "d · EEE"
        return formatter.string(from: date)
    }

    private func legacy(_ totals: [String: DayTotal], marks: [String: [Color]], out: Double, inn: Double) -> some View {
        VStack(spacing: AppSpacing.icon) {
            // equal columns, each centred: a month's longer amounts don't push 收入 sideways
            FigureRow(items: [
                .init(label: LS("支出"), value: money(out, L.base, 0), color: Self.spend),
                .init(label: LS("收入"), value: money(inn, L.base, 0), color: Self.earn),
                .init(label: LS("结余"), value: money(inn - out, L.base, 0), color: inn - out < 0 ? Color.loss : Color.primary),
            ], alignment: .center)
            .padding(.vertical, AppSpacing.detail)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("calendar.figures")
            MonthCalendar(marks: marks, month: $month, last: Day.today(), describe: { d in
                totals[d].flatMap { x in
                    let parts = [x.out > 0.005 ? LS("支出 ") + money(x.out) : nil, x.inn > 0.005 ? LS("收入 ") + money(x.inn) : nil].compactMap { $0 }
                    return parts.isEmpty ? (x.n > 0 ? LS("%@ 笔其他交易", x.n) : nil) : parts.joined(separator: " ")
                }
            }, pick: pick)
            legend
        }
    }

    /// after the search changed: show the latest month with something in it, if this one has nothing
    private func follow() {
        guard !entries.contains(where: { $0.date.hasPrefix(month) }), let latest = entries.first else { return }
        month = Day.ym(latest.date)
    }

    /// what the dots mean, under the days
    private var legend: some View {
        HStack(spacing: AppSpacing.control) {
            HStack(spacing: AppSpacing.detail) {
                Circle().fill(Self.spend).frame(width: 6, height: 6)
                Text(LS("支出"))
            }
            HStack(spacing: AppSpacing.detail) {
                Circle().fill(Self.earn).frame(width: 6, height: 6)
                Text(LS("收入"))
            }
            HStack(spacing: AppSpacing.detail) {
                Circle().fill(Self.other).frame(width: 6, height: 6)
                Text(LS("其他交易"))
            }
            Spacer()
            Text(LS("点日期看当天明细"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}


/// Intensity only; financial amounts stay in JournalCalendar's existing aggregation.
struct DayMark {
    var out: Int = 0
    var inn: Int = 0
    var other = false
}

/// Six fixed rows, shared by Journal and subscriptions. Selection is separate from opening a day's details.
struct GlassMonthCalendar<Totals: View, Summary: View, Footer: View>: View {
    var marks: [String: DayMark]
    @Binding var month: String
    var first = "2000-01-01"
    var last: String
    var describe: (String) -> String? = { _ in nil }
    @Binding var selection: String?
    var showsToday = false
    var themeMarks = false
    var pickImmediately = false
    var pick: (String) -> Void
    @ViewBuilder var totals: () -> Totals
    @ViewBuilder var summary: () -> Summary
    @ViewBuilder var footer: () -> Footer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var cellHeight: CGFloat = 50
    @ScaledMetric(relativeTo: .body) private var dateSize: CGFloat = 17
    @State private var pickingMonth = false
    @State private var wheelYear = 2026
    @State private var wheelMonth = 1
    @State private var forward = true

    private var calendar: Calendar {
        var c = Day.calendar
        c.locale = AppLanguage.current.locale
        // firstWeekday follows the chosen locale rather than the language of the compiled app.
        var localized = Calendar(identifier: .gregorian)
        localized.locale = AppLanguage.current.locale
        c.firstWeekday = localized.firstWeekday
        return c
    }
    private var days: [String] {
        guard let start = Day.date(month + "-01") else { return [] }
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return (0..<42).map { Day.shift(month + "-01", $0 - offset) }
    }
    private var weekdays: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }
    private func enabled(_ d: String) -> Bool { d.hasPrefix(month) && d >= first && d <= last }
    private func canStep(_ offset: Int) -> Bool {
        let m = Day.addMonth(month, offset)
        return m >= Day.ym(first) && m <= Day.ym(last)
    }
    private func changeMonth(_ value: String) {
        let target = min(max(value, Day.ym(first)), Day.ym(last))
        guard target != month else { return }
        forward = target > month
        month = target
        Haptics.selection()
    }

    var body: some View {
        VStack(spacing: AppSpacing.icon) {
            navigation
            totals()
            HStack(spacing: 0) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                    Text(name).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }.accessibilityHidden(true)
            ZStack { grid }
                .animation(AppMotion.standard, value: month)
            summary()
            footer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.glass")
        .sheet(isPresented: $pickingMonth) { monthPicker }
    }

    private var navigation: some View {
        HStack(spacing: AppSpacing.icon) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    wheelYear = Int(month.prefix(4)) ?? 2026
                    wheelMonth = Int(month.suffix(2)) ?? 1
                    pickingMonth = true
                } label: {
                    HStack(spacing: AppSpacing.detail) {
                        Text(Day.monthLabel(month))
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.system(.headline, design: .rounded)).foregroundStyle(Color.primary)
                    .lineLimit(1).minimumScaleFactor(0.5)
                }
                .accessibilityIdentifier("calendar.monthTitle")
                if showsToday {
                    Button(LS("回到本月")) { changeMonth(Day.ym(Day.today())) }
                        .font(.caption2).foregroundStyle(Color.jadeInk)
                        .opacity(month == Day.ym(Day.today()) ? 0 : 1)
                        .disabled(month == Day.ym(Day.today()))
                        .accessibilityHidden(month == Day.ym(Day.today()))
                }
            }
            Spacer(minLength: 0)
            arrow("chevron.left", label: LS("上个月"), offset: -1)
            arrow("chevron.right", label: LS("下个月"), offset: 1)
        }
        .buttonStyle(.plain)
    }

    private func arrow(_ symbol: String, label: String, offset: Int) -> some View {
        Button { changeMonth(Day.addMonth(month, offset)) } label: {
            Image(systemName: symbol).font(.body.weight(.semibold))
                .foregroundStyle(Color.jadeInk).frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
        }
        .disabled(!canStep(offset)).opacity(canStep(offset) ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    private var grid: some View {
        let dates = days
        return GeometryReader { geometry in
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(Array(dates.dropFirst(row * 7).prefix(7)), id: \.self) { d in
                            cell(d, width: geometry.size.width / 7)
                        }
                    }
                }
            }
        }
        .frame(height: cellHeight * 6)
        .id(month)
        .transition(.asymmetric(insertion: .offset(x: reduceMotion ? 0 : forward ? 12 : -12).combined(with: .opacity), removal: .opacity))
        .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
            guard abs(value.translation.width) >= 40, abs(value.translation.width) > abs(value.translation.height) else { return }
            let step = value.translation.width < 0 ? 1 : -1
            if canStep(step) { changeMonth(Day.addMonth(month, step)) }
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.grid")
    }

    private func cell(_ d: String, width: CGFloat) -> some View {
        let today = d == Day.today()
        let selected = selection == d
        let mark = marks[d] ?? DayMark()
        return Button {
            let repeated = selection == d
            selection = d
            Haptics.selection()
            if pickImmediately || repeated { pick(d) }
        } label: {
            VStack(spacing: 2) {
                Text(String(Int(d.suffix(2)) ?? 1))
                    .font(.system(.body, design: .rounded).weight(selected ? .semibold : .regular))
                    .fixedSize()
                    // Rounded numerals have no compressed font face. Compress width only at AX3+;
                    // their full Dynamic Type height remains, without overlapping adjacent dates.
                    .scaleEffect(x: typeSize >= .accessibility3 ? min(1, (width - 6) / (dateSize * 1.3)) : 1, y: 1)
                    .foregroundStyle(today ? Color.onJade : selected ? Color.jadeInk : Color.primary)
                    .frame(width: width, height: dateSize * 1.9)
                    .background {
                        Circle().fill(today ? Color.jade : selected ? Color.jade.opacity(0.2) : Color.clear)
                            .frame(width: min(dateSize * 1.9, width - 2), height: min(dateSize * 1.9, width - 2))
                    }
                HStack(spacing: 3) {
                    if mark.out > 0 || mark.inn > 0 {
                        dot(level: mark.out, color: themeMarks ? .jade : .loss).opacity(mark.out > 0 ? 1 : 0)
                        if !themeMarks { dot(level: mark.inn, color: .gain).opacity(mark.inn > 0 ? 1 : 0) }
                    } else if mark.other {
                        dot(level: 1, color: .secondary)
                    }
                }
                .frame(height: 7).accessibilityHidden(true)
            }
            .frame(width: width, height: cellHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled(d))
        .opacity(!d.hasPrefix(month) ? 0.3 : enabled(d) ? 1 : 0.35)
        .accessibilityLabel(Day.dayLabel(d) + (describe(d).map { " · " + $0 } ?? ""))
        .accessibilityValue(selected ? LS("已选中") : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHidden(!d.hasPrefix(month))
        .accessibilityIdentifier("calendar.day." + d)
    }

    private func dot(level: Int, color: Color) -> some View {
        let size: CGFloat = level == 1 ? 4 : level == 2 ? 5.5 : 7
        return Circle().fill(color).frame(width: size, height: size).frame(width: 7, height: 7)
    }

    private var monthPicker: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker(LS("年"), selection: $wheelYear) {
                    ForEach((Int(first.prefix(4)) ?? 2000)...(Int(last.prefix(4)) ?? 2100), id: \.self) { y in
                        Text(String(y)).tag(y)
                    }
                }
                .accessibilityIdentifier("calendar.yearWheel")
                Picker(LS("月"), selection: $wheelMonth) {
                    ForEach(1...12, id: \.self) { m in Text(String(m)).tag(m) }
                }
                .accessibilityIdentifier("calendar.monthWheel")
            }
            .pickerStyle(.wheel)
            .navigationTitle(LS("选择年月")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { pickingMonth = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LS("完成")) {
                        changeMonth(String(format: "%04d-%02d", wheelYear, wheelMonth))
                        pickingMonth = false
                    }
                }
            }
        }
        .pickerSheet()
    }
}

/// One month calendar for the whole app: the system's (UICalendarView), in the theme colour, with up to three dots
/// under each day in its colours. The system draws the header, pages from month to month and offers its month and
/// year wheel. Days are "YYYY-MM-DD", months "YYYY-MM".
struct MonthCalendar: UIViewRepresentable {
    /// the dots under each day, left to right (spending in the theme colour, then income in green, or grey)
    var marks: [String: [Color]]
    /// the month on screen; changed here to move the calendar, set by it when the user swipes
    @Binding var month: String
    /// the first and last days that can be picked (the journal goes back years and up to today; coming charges
    /// start today)
    var first: String = "2000-01-01"
    var last: String
    /// what VoiceOver reads with the day's dots ("支出 ¥12.00"), when there is something
    var describe: (String) -> String? = { _ in nil }
    var pick: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICalendarView {
        let v = UICalendarView()
        v.calendar = Day.calendar
        v.locale = AppLanguage.current.locale
        v.fontDesign = .rounded
        v.tintColor = Self.tint(context)
        v.delegate = context.coordinator
        v.selectionBehavior = UICalendarSelectionSingleDate(delegate: context.coordinator)
        v.setContentHuggingPriority(.required, for: .vertical)
        v.accessibilityIdentifier = "calendar.month"
        context.coordinator.apply(self, to: v, animated: false)
        return v
    }

    func updateUIView(_ v: UICalendarView, context: Context) {
        v.tintColor = Self.tint(context)
        context.coordinator.apply(self, to: v, animated: true)
    }

    /// the theme colour as this screen draws it (light or dark), for today, the days and the arrows
    private static func tint(_ context: Context) -> UIColor {
        UIColor(cgColor: Color.jade.resolve(in: context.environment).cgColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fit = uiView.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                 withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: fit.height)
    }

    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: MonthCalendar
        private var shown: [String: [Color]] = [:]
        init(_ parent: MonthCalendar) { self.parent = parent }

        private static func components(_ day: String) -> DateComponents? {
            let p = day.split(separator: "-").compactMap { Int($0) }
            guard p.count >= 2 else { return nil }
            return DateComponents(calendar: Day.calendar, year: p[0], month: p[1], day: p.count > 2 ? p[2] : 1)
        }

        private static func day(_ c: DateComponents) -> String? {
            guard let y = c.year, let m = c.month, let d = c.day else { return nil }
            return String(format: "%04d-%02d-%02d", y, m, d)
        }

        func apply(_ next: MonthCalendar, to v: UICalendarView, animated: Bool) {
            parent = next
            if let start = Day.date(next.first), let end = Day.date(next.last) {
                let range = DateInterval(start: start, end: max(start, end))
                if v.availableDateRange != range { v.availableDateRange = range }
            }
            // only the days whose dots changed are drawn again
            let changed = Set(shown.keys).union(next.marks.keys).filter { shown[$0] != next.marks[$0] }
            shown = next.marks
            let comps = changed.compactMap(Self.components)
            if !comps.isEmpty { v.reloadDecorations(forDateComponents: comps, animated: animated) }
            let visible = v.visibleDateComponents
            if let want = Self.components(next.month + "-01"), visible.year != want.year || visible.month != want.month {
                v.setVisibleDateComponents(want, animated: animated)
            }
        }

        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            guard let d = Self.day(dateComponents), let colors = shown[d], !colors.isEmpty else { return nil }
            let said = parent.describe(d)
            return .customView {
                let dots = colors.prefix(3).map { c -> UIView in
                    let v = UIView()
                    v.backgroundColor = UIColor(c)
                    v.layer.cornerRadius = 2.5
                    v.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([v.widthAnchor.constraint(equalToConstant: 5), v.heightAnchor.constraint(equalToConstant: 5)])
                    return v
                }
                let stack = UIStackView(arrangedSubviews: Array(dots))
                stack.axis = .horizontal
                stack.spacing = 3
                stack.translatesAutoresizingMaskIntoConstraints = false
                // the system puts a decoration at the day's leading edge at the size it asks for, not centred: it takes
                // the day's whole width and centres the dots in it, under the date
                let box = DayDots()
                box.addSubview(stack)
                box.translatesAutoresizingMaskIntoConstraints = false
                let width = CGFloat(dots.count) * 5 + CGFloat(dots.count - 1) * 3
                NSLayoutConstraint.activate([
                    stack.centerXAnchor.constraint(equalTo: box.centerXAnchor), stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                    box.widthAnchor.constraint(greaterThanOrEqualToConstant: width), box.heightAnchor.constraint(equalToConstant: 5),
                ])
                box.isAccessibilityElement = said != nil
                box.accessibilityLabel = said
                box.accessibilityIdentifier = "calendar.dots." + d
                return box
            }
        }

        func calendarView(_ calendarView: UICalendarView, didChangeVisibleDateComponentsFrom previous: DateComponents) {
            let c = calendarView.visibleDateComponents
            guard let y = c.year, let m = c.month else { return }
            let month = String(format: "%04d-%02d", y, m)
            if month != parent.month { DispatchQueue.main.async { self.parent.month = month } }
        }

        /// A tap only picks the day: the system marks a selected day in black, not in the theme colour, so the
        /// mark is taken off at once and the screen says which day is open (its sheet, or the list's heading).
        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard let d = dateComponents.flatMap(Self.day) else { return }
            selection.setSelected(nil, animated: true)
            parent.pick(d)
        }
    }
}

/// a day's dots, as wide as the day it sits in
private final class DayDots: UIView {
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard let day = superview else { return }
        NSLayoutConstraint.activate([leadingAnchor.constraint(equalTo: day.leadingAnchor), trailingAnchor.constraint(equalTo: day.trailingAnchor)])
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
    @Environment(Store.self) var store
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
                    VStack(alignment: .leading, spacing: AppSpacing.control) {
                        HStack(spacing: AppSpacing.control) {
                            Figure(label: LS("收入"), value: money(inn, L.base), color: .gain)
                            Spacer()
                            Figure(label: LS("支出"), value: money(out, L.base), color: JournalCalendar.spend)
                            Spacer()
                            Figure(label: LS("纯利"), value: money(inn - out, L.base), color: inn - out < 0 ? Color.loss : Color.primary, alignment: .trailing)
                        }
                        .sensitive()
                        if !flows.isEmpty { FlowBars(flows: flows) }
                    }
                    .padding(.vertical, AppSpacing.detail)
                } footer: {
                    if flows.count > 1 { Text(LS("上面的合计折算为 %@；条形图按原币种。", L.base)) }
                }
                Section(LS("交易 · %@ 笔", entries.count)) {
                    if entries.isEmpty { Text(LS("这一天没有交易")).foregroundStyle(.secondary) }
                    ForEach(entries, id: \.id) { t in
                        Button { open(t) } label: {
                            HStack(spacing: AppSpacing.control) {
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
                                HStack(spacing: AppSpacing.icon) {
                                    Image(systemName: "doc.text").foregroundStyle(Color.jadeInk)
                                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) } } }
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
                    .accessibilityLabel(f.currency + " " + inc).accessibilityValue(money(f.income, f.currency))
                BarMark(x: .value("金额", f.expenses), y: .value("币种", f.currency), height: .ratio(0.32))
                    .foregroundStyle(by: .value("类型", exp))
                    .position(by: .value("类型", exp), axis: .vertical)
                    .annotation(position: .trailing) { label(f.expenses) }
                    .accessibilityLabel(f.currency + " " + exp).accessibilityValue(money(f.expenses, f.currency))
                BarMark(x: .value("金额", f.net), y: .value("币种", f.currency), height: .fixed(3))
                    .foregroundStyle(by: .value("类型", net))
                    .accessibilityLabel(f.currency + " " + net).accessibilityValue(money(f.net, f.currency))
            }
            RuleMark(x: .value("零", 0)).foregroundStyle(Color.secondary.opacity(0.5))
        }
        // the calendar's colours: spending in the theme colour, income green, the net a plain line
        .chartForegroundStyleScale([inc: JournalCalendar.earn, exp: JournalCalendar.spend, net: Color.primary.opacity(0.6)])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel() } }
        .frame(height: CGFloat(flows.count) * 64 + 44)
        .sensitive(xAxis: true)
    }

    private func label(_ v: Double) -> some View {
        Text(abs(v) < 0.005 ? "" : masked(fmtNum(v))).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
    }
}
