import Foundation

// The journal and subscription calendars share these. The view draws; the numbers and the grid are decided here.
//
// PR #1 (`cursor/derived-single-pass-90f0`, not merged) stores each transaction's spending and income on
// `Derived.journalOut` / `journalIn` — the same two numbers `classify` produces, indexed by `Entry.id`.
// It does not bucket them by day. After that lands, a day's total can sum those arrays by `date` instead of
// calling `classify` again. `compactAmount`, `heatIntensity` and `monthGrid` do not overlap with it.

/// Spending and income of one day, in the ledger's operating currency.
/// Spending is what `classify` calls an expense; a refund lowers it and can leave it negative.
/// Income on a transaction that also has an expense is not counted again (it stays inside that expense).
/// Transfers, advances and reimbursements are neither, and a day with neither is left out.
public struct DayMoney: Equatable {
    public var expense: Double
    public var income: Double
    public init(expense: Double = 0, income: Double = 0) {
        self.expense = expense
        self.income = income
    }
}

public func dayMoney(_ entries: [Entry], _ L: Ledger) -> [String: DayMoney] {
    var totals: [String: DayMoney] = [:]
    for t in entries {
        let c = classify(t, L)
        var slot = totals[t.date] ?? DayMoney()
        switch c.kind {
        case .expense, .refund: slot.expense -= c.amount
        case .income: slot.income += c.amount
        case .transfer: break
        }
        totals[t.date] = slot
    }
    var out: [String: DayMoney] = [:]
    for (day, raw) in totals {
        let money = DayMoney(expense: roundTo(raw.expense, 2), income: roundTo(raw.income, 2))
        if abs(money.expense) > 0.004 || abs(money.income) > 0.004 { out[day] = money }
    }
    return out
}

/// A day's amount inside a calendar cell: 72, 1.2k, 1.5m. Under 1000 it is a whole number; 0.5 and up rounds.
/// Nothing small enough to round to 0. The sign is dropped — a cell only shows spending, which is positive.
public func compactAmount(_ amount: Double) -> String {
    let n = abs(amount)
    if n < 0.5 { return "" }
    if n < 999.5 { return String(Int(n.rounded())) }
    let millions = n >= 999_500
    let scaled = n / (millions ? 1_000_000 : 1_000)
    let tenths = (scaled * 10).rounded() / 10
    let suffix = millions ? "m" : "k"
    let whole = Int(tenths.rounded())
    if abs(tenths - Double(whole)) < 0.001 { return "\(whole)\(suffix)" }
    let digits = Int((tenths * 10).rounded())
    return "\(digits / 10).\(abs(digits % 10))\(suffix)"
}

/// How strong a day's colour is, from 0 to 1, on a log scale against the strongest day.
/// A single very large day stays the darkest and the ordinary days stay visible; a linear scale would flatten them.
/// No spending, or no peak, is 0. Anything past the peak is 1.
public func heatIntensity(amount: Double, peak: Double) -> Double {
    guard amount > 0, peak > 0 else { return 0 }
    let top = log1p(peak)
    guard top > 0 else { return 1 }
    return min(1, max(0, log1p(amount) / top))
}

/// One cell of a month laid out as six rows of seven days. `inMonth` is false for the days borrowed from the
/// months on either side so the grid never changes height.
public struct CalendarCell: Equatable {
    public let date: String
    public let inMonth: Bool
    public init(date: String, inMonth: Bool) {
        self.date = date
        self.inMonth = inMonth
    }
}

/// 42 days covering `month` (`YYYY-MM`). `firstWeekday` is the system's: 1 is Sunday … 7 is Saturday.
/// Anything outside 1…7 is treated as Sunday. A month that is not a real `YYYY-MM` is an empty grid.
public func monthGrid(month: String, firstWeekday: Int) -> [CalendarCell] {
    guard month.count == 7, month.dropFirst(4).first == "-",
          let year = Int(month.prefix(4)), let mo = Int(month.suffix(2)), (1...12).contains(mo) else { return [] }
    let fw = (1...7).contains(firstWeekday) ? firstWeekday : 1
    let first = String(format: "%04d-%02d-01", year, mo)
    guard let date = Day.date(first) else { return [] }
    let weekday = Day.calendar.component(.weekday, from: date)
    let lead = (weekday - fw + 7) % 7
    let start = Day.shift(first, -lead)
    return (0..<42).map { i in
        let day = Day.shift(start, i)
        return CalendarCell(date: day, inMonth: day.hasPrefix(month))
    }
}

/// Which of the six rows holds `day`, if it is on this grid.
public func calendarRow(of day: String, in cells: [CalendarCell]) -> Int? {
    guard let i = cells.firstIndex(where: { $0.date == day }) else { return nil }
    return i / 7
}
