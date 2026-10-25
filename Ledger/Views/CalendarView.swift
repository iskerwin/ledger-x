import SwiftUI
import LedgerKit

/// One day on the heat calendar. `amount` is what the cell writes and colours (spending, or a subscription charge).
/// `income` above nothing draws the green corner dot and is not written as a number.
struct HeatDay: Equatable {
    var amount: Double = 0
    var income: Double = 0
}

/// The month calendar the journal and the subscription page share. Six rows every month, so whatever sits under it
/// stays put while the month changes. `collapsible` folds it to the week of today (or of the selected day); the
/// subscription page leaves it open. Amounts and the grid come from LedgerKit. While amounts are hidden the cells
/// drop the number and the heat, so the colour cannot give the amount away.
struct HeatCalendar<Summary: View>: View {
    @Binding var month: String
    var days: [String: HeatDay]
    var selected: String?
    var collapsible: Bool
    @Binding var expanded: Bool
    var canGoBack: Bool
    var canGoOn: Bool
    /// days outside this inclusive range are shown and cannot be picked (the subscription page starts at today)
    var earliest: String?
    var latest: String?
    var onPick: (String) -> Void
    var onToday: () -> Void
    var describe: (String, HeatDay) -> String
    @ViewBuilder var summary: () -> Summary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 48
    @State private var shown: String?

    private var masked: Bool { KitSettings.shared.masked }
    private var open: Bool { expanded || !collapsible }
    private var gap: CGFloat { AppSpacing.detail }
    private var block: CGFloat { rowHeight + gap }
    private var fullHeight: CGFloat { rowHeight * 6 + gap * 5 }

    var body: some View {
        let first = Calendar.current.firstWeekday
        let cells = monthGrid(month: month, firstWeekday: first)
        let focus = focusRow(cells)
        let rows = cells.count == 42 ? 6 : 0
        let peak = cells.reduce(0.0) { best, cell in
            guard cell.inMonth, let amount = days[cell.date]?.amount, amount > best else { return best }
            return amount
        }
        VStack(spacing: AppSpacing.icon) {
            header
            VStack(spacing: gap) {
                weekdayRow(first)
                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { column in
                                dayCell(cells[row * 7 + column], peak: peak)
                            }
                        }
                        .frame(height: rowHeight)
                    }
                }
                .offset(y: open ? 0 : -CGFloat(focus) * block)
                .frame(height: open ? fullHeight : rowHeight, alignment: .top)
                .clipped()
                .animation(reduceMotion ? nil : AppMotion.standard, value: open)
                .animation(reduceMotion ? nil : AppMotion.standard, value: focus)
                .accessibilityIdentifier("calendar.grid")
            }
            .monthSwipe(back: { step(-1) }, forward: canGoOn ? { step(1) } : nil)
            if collapsible { grabber }
        }
        .accessibilityIdentifier("calendar.month")
        .onAppear { shown = month }
        .onChange(of: month) { _, next in shown = next }
    }

    private var away: Bool {
        let today = Day.today()
        if month != Day.ym(today) { return true }
        if let selected, selected != today { return true }
        return false
    }

    private var header: some View {
        HStack(spacing: AppSpacing.detail) {
            arrow("chevron.left", LS("上个月"), enabled: canGoBack) { step(-1) }
            ZStack {
                Text(PeriodBar.widestMonth(month)).font(.headline).lineLimit(1).minimumScaleFactor(0.5)
                    .hidden().accessibilityHidden(true)
                SlidingTitle(text: Day.monthLabel(month), forward: month >= (shown ?? month)).font(.headline)
                    .accessibilityIdentifier("calendar.title")
                    .accessibilityValue(month)
            }
            .layoutPriority(1)
            arrow("chevron.right", LS("下个月"), enabled: canGoOn) { step(1) }
            Spacer(minLength: AppSpacing.detail)
            summary()
                .frame(minWidth: 0, alignment: .trailing)
            ZStack {
                todayButton.hidden().accessibilityHidden(true)
                if away { todayButton.transition(.opacity) }
            }
            .animation(reduceMotion ? nil : AppMotion.quick, value: away)
        }
    }

    private var todayButton: some View {
        Button(action: onToday) {
            Text(LS("今天")).font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.detail)
                .foregroundStyle(Color.jade)
                .background(Color.jade.soft, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("calendar.today")
    }

    private func arrow(_ symbol: String, _ label: String, enabled: Bool, _ go: @escaping () -> Void) -> some View {
        Button(action: go) {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(minWidth: 24, minHeight: 28)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
        .buttonStyle(.plain)
    }

    private func weekdayRow(_ firstWeekday: Int) -> some View {
        let symbols = weekdayTitles(firstWeekday)
        return HStack(spacing: gap) {
            ForEach(symbols.indices, id: \.self) { i in
                Text(symbols[i]).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    /// the system's short weekday names, rotated so column 0 is `Calendar.current.firstWeekday`
    private func weekdayTitles(_ firstWeekday: Int) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = AppLanguage.current.locale
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let start = min(6, max(0, firstWeekday - 1))
        return (0..<7).map { symbols[(start + $0) % 7] }
    }

    private func focusRow(_ cells: [CalendarCell]) -> Int {
        if let selected, let row = calendarRow(of: selected, in: cells) { return row }
        if let row = calendarRow(of: Day.today(), in: cells) { return row }
        return 0
    }

    private func allows(_ date: String) -> Bool {
        if let earliest, date < earliest { return false }
        if let latest, date > latest { return false }
        return true
    }

    private func step(_ delta: Int) {
        guard delta < 0 ? canGoBack : canGoOn else { return }
        month = Day.addMonth(month, delta)
    }

    @ViewBuilder private func dayCell(_ cell: CalendarCell, peak: Double) -> some View {
        let mark = days[cell.date] ?? HeatDay()
        let on = selected == cell.date
        let today = cell.date == Day.today()
        let live = allows(cell.date)
        let showFigure = cell.inMonth && live && !masked && mark.amount > 0.005
        let amount = showFigure ? compactAmount(mark.amount) : ""
        let heat = (cell.inMonth && live && !masked) ? heatIntensity(amount: mark.amount, peak: peak) : 0
        let label = live ? describe(cell.date, mark) : Day.dayLabel(cell.date)
        let body = ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                Text(String(Int(cell.date.suffix(2)) ?? 0))
                    .font(.subheadline.weight(on ? .bold : .medium).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(amount.isEmpty ? " " : amount)
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .opacity(amount.isEmpty ? 0 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(on ? Color.onJade : (cell.inMonth && live ? Color.primary : Color.secondary.opacity(0.45)))
            .background(fill(on: on, heat: heat), in: RoundedRectangle(cornerRadius: AppRadius.tile, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.tile, style: .continuous)
                    .strokeBorder(today ? (on ? Color.onJade : Color.jade) : Color.clear, lineWidth: today ? (on ? 2 : 1.5) : 0)
            }
            if cell.inMonth && live && !masked && mark.income > 0.005 {
                Circle().fill(on ? Color.onJade : Color.gain).frame(width: 6, height: 6)
                    .padding(3)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("calendar.income." + cell.date)
            }
        }
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : AppMotion.quick, value: on)
        if live {
            Button { onPick(cell.date) } label: { body }
                .buttonStyle(PressStyle())
                .accessibilityLabel(label)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("calendar.day." + cell.date)
        } else {
            body.accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityIdentifier("calendar.day." + cell.date)
        }
    }

    private func fill(on: Bool, heat: Double) -> Color {
        if on { return Color.jade }
        if heat <= 0 { return Color.clear }
        return Color.jade.opacity(0.16 + 0.56 * heat)
    }

    /// tap toggles; a downward drag opens the month and an upward drag folds it. Once the finger has moved, the
    /// drag takes the touch and the button does not also toggle.
    private var grabber: some View {
        Button { setOpen(!expanded) } label: {
            Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? LS("收起为一周") : LS("展开整月"))
        .accessibilityIdentifier("calendar.grabber")
        .highPriorityGesture(DragGesture(minimumDistance: 18).onEnded { value in
            let dy = value.translation.height
            guard abs(dy) > 18 else { return }
            setOpen(dy > 0)
        })
    }

    private func setOpen(_ on: Bool) {
        guard expanded != on else { return }
        withAnimation(reduceMotion ? nil : AppMotion.standard) { expanded = on }
        Haptics.selection()
    }
}

/// 明细's calendar, above the list. It counts the transactions the list is showing (search and account included,
/// the picked day not included, or picking a day would wipe the other days). A picked day is the list's filter.
struct JournalCalendar: View {
    let L: Ledger
    /// the transactions the list would show, newest first, before a single day is picked
    let entries: [Entry]
    var selected: String?
    var onPick: (String) -> Void
    var onToday: () -> Void
    @State private var month = Day.ym(Day.today())
    @State private var expanded = UserDefaults.standard.bool(forKey: Self.expandedKey)
    /// remembered between launches. A plain @State drives the fold: an @AppStorage change loses the animation.
    static let expandedKey = "ledger.journal.calendar"

    /// spending in the theme colour, income in the app's gain colour (the subscription calendar's dots still use this)
    static var spend: Color { Color.jade }
    static var earn: Color { Color.gain }

    var body: some View {
        let byDay = dayMoney(entries, L)
        let spent = byDay.reduce(0.0) { $1.key.hasPrefix(month) ? $0 + $1.value.expense : $0 }
        let earned = byDay.reduce(0.0) { $1.key.hasPrefix(month) ? $0 + $1.value.income : $0 }
        var marks: [String: HeatDay] = [:]
        for (day, money) in byDay { marks[day] = HeatDay(amount: money.expense, income: money.income) }
        let today = Day.ym(Day.today())
        return HeatCalendar(month: $month, days: marks, selected: selected, collapsible: true, expanded: $expanded,
                            canGoBack: month > "2000-01", canGoOn: month < today, earliest: nil, latest: nil,
                            onPick: pick, onToday: backToToday, describe: spoken) {
            HStack(spacing: AppSpacing.detail) {
                Text(LS("支出 ") + money(spent, L.base, 0)).foregroundStyle(Color.jade).rollingNumber(spent)
                Text("·").foregroundStyle(.secondary)
                Text(LS("收入 ") + money(earned, L.base, 0)).foregroundStyle(Color.gain).rollingNumber(earned)
            }
            .font(.caption.monospacedDigit())
            .lineLimit(1).minimumScaleFactor(0.5)
            .sensitive()
            .accessibilityIdentifier("calendar.totals")
        }
        .onAppear(perform: follow)
        .onChange(of: entries.first?.date) { _, _ in follow() }
        .onChange(of: expanded) { _, on in UserDefaults.standard.set(on, forKey: Self.expandedKey) }
    }

    private func pick(_ date: String) {
        if Day.ym(date) != month { month = Day.ym(date) }
        onPick(date)
        Haptics.selection()
    }

    private func backToToday() {
        month = Day.ym(Day.today())
        onToday()
    }

    /// after the search changed: show the latest month that has anything, when this one does not
    private func follow() {
        guard !entries.contains(where: { $0.date.hasPrefix(month) }), let latest = entries.first else { return }
        month = Day.ym(latest.date)
    }

    private func spoken(_ date: String, _ day: HeatDay) -> String {
        var lead = Day.dayLabel(date)
        if date == Day.today() { lead = LS("今天") + " " + lead }
        if KitSettings.shared.masked { return lead + "，" + LS("金额已隐藏") }
        var parts = [lead]
        if abs(day.amount) > 0.005 { parts.append(LS("支出 ") + plainMoney(day.amount, L.base)) }
        if day.income > 0.005 { parts.append(LS("收入 ") + plainMoney(day.income, L.base)) }
        return parts.joined(separator: "，")
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

/// One month calendar for the subscription page until it moves onto `HeatCalendar`: the system's (UICalendarView),
/// in the theme colour, with up to three dots under each day. Days are "YYYY-MM-DD", months "YYYY-MM".
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
