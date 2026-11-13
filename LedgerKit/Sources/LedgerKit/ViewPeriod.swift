import Foundation

/// the stretch of time a window's pages look at, as Fava's time filter: the month, quarter or year holding `month`,
/// the last 30 days, one day, a span of days, or all time. Never past the current month or today
public struct ViewPeriod: Hashable, Sendable {
    public enum Unit: String, CaseIterable, Sendable { case month, quarter, year, recent, all }

    /// days picked from one to another, both kept
    public struct Days: Hashable, Sendable {
        public let from: String
        public let to: String
        public init(from: String, to: String) {
            self.from = min(from, to)
            self.to = max(from, to)
        }
    }

    public var unit: Unit
    /// the month in it: for a quarter or year, the one stepping lands on
    public var month: String
    /// one day, picked on the calendar; the unit stays for when it's put away
    public var day: String?
    /// a span of days picked; over a day and the unit, which stay for when it's put away
    public var days: Days?

    public init(unit: Unit = .month, month: String = Day.ym(Day.today()), day: String? = nil, days: Days? = nil) {
        self.unit = unit
        self.month = month
        self.day = day
        self.days = days
    }

    /// first and last day; nil for all time
    public var span: (String, String)? {
        if let days { return (days.from, days.to) }
        if let day { return (day, day) }
        let year = String(month.prefix(4))
        switch unit {
        case .month: return (month + "-01", Day.monthEnd(month))
        case .quarter: return (quarterStart + "-01", Day.monthEnd(Day.addMonth(quarterStart, 2)))
        case .year: return (year + "-01-01", year + "-12-31")
        case .recent:
            let today = Day.today()
            return (Day.shift(today, -29), today)
        case .all: return nil
        }
    }

    /// the arrows step it: a month, quarter, year or day; not the last 30 days, a span of days or all time
    public var steps: Bool { days == nil && (day != nil || (unit != .recent && unit != .all)) }

    /// the month a page that shows months or years is about: the last day's, or the one in the period
    public var anchor: String {
        if let days { return Day.ym(days.to) }
        if day == nil && unit == .recent { return Day.ym(Day.today()) }
        return day.map(Day.ym) ?? month
    }

    /// a page that shows a month or a year (概览, 预算): a year for a year or all time, else a month
    public var byYear: Bool { days == nil && day == nil && (unit == .year || unit == .all) }

    /// holds today
    public var isCurrent: Bool {
        let today = Day.today()
        guard let span else { return true }
        return span.0 <= today && today <= span.1
    }

    /// "2026 年 11 月", "2026 年第 4 季度", "2026 年", "近 30 天", "全部时间", "11月9日 周一", "2026-10-03 至 2026-11-11"
    public var title: String {
        if let days { return days.from == days.to ? Day.dayLabel(days.from) : "\(days.from) 至 \(days.to)" }
        if let day { return Day.dayLabel(day) }
        let year = month.prefix(4)
        switch unit {
        case .month: return "\(year) 年 \(Int(month.suffix(2)) ?? 0) 月"
        case .quarter: return "\(year) 年第 \(quarter) 季度"
        case .year: return "\(year) 年"
        case .recent: return "近 30 天"
        case .all: return "全部时间"
        }
    }

    /// what it's called while it holds today: "本月", "本季度", "今年", "今天"; a span of days by its title
    public var current: String {
        if days != nil { return title }
        if day != nil { return "今天" }
        switch unit {
        case .month: return "本月"
        case .quarter: return "本季度"
        case .year: return "今年"
        case .recent: return "近 30 天"
        case .all: return "全部时间"
        }
    }

    /// the one before or after, never past the current one; all time has none
    public func stepped(_ by: Int) -> ViewPeriod {
        guard steps else { return self }
        var next = self
        if let day {
            next.day = min(Day.shift(day, by), Day.today())
            return next
        }
        let months: Int
        switch unit {
        case .month: months = by
        case .quarter: months = by * 3
        case .year: months = by * 12
        case .recent, .all: return self
        }
        next.month = min(Day.addMonth(month, months), Day.ym(Day.today()))
        return next
    }

    /// the same month seen as another unit; the day put away
    public func showing(_ unit: Unit) -> ViewPeriod { ViewPeriod(unit: unit, month: anchor) }

    private var quarter: Int { ((Int(month.suffix(2)) ?? 1) - 1) / 3 + 1 }
    private var quarterStart: String { String(month.prefix(4)) + String(format: "-%02d", (quarter - 1) * 3 + 1) }
}
