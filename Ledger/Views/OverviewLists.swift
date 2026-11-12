import SwiftUI
import LedgerKit

// The overview's list-style charts: a ranked list of categories with bars (and the change from the period
// before), a payee ranking with bars, and each liability's use of its credit limit.

enum OverviewChart {
    static let styleKey = "ledger.overview.chart"
    static let trendKey = "ledger.overview.trend"
}

/// "↑ ¥320" against the period before: red when spending went up, green when down; faint when small
struct DeltaText: View {
    let now: Double
    let before: Double
    @Environment(\.displayCurrency) private var cur
    var body: some View {
        let d = now - before
        let big = before > 0 ? abs(d) / before >= 0.2 && abs(d) >= 1 : now > 0
        Group {
            if before <= 0.005 && now > 0.005 {
                Text(LS("新增"))
            } else if abs(d) < 0.5 {
                Text(LS("持平"))
            } else {
                Text((d > 0 ? "↑ " : "↓ ") + money(abs(d), cur, 0))
            }
        }
        .font(.caption2.weight(big ? .semibold : .regular).monospacedDigit())
        .foregroundStyle(abs(d) < 0.5 ? Color.secondary : d > 0 ? Color.loss : Color.gain)
        .opacity(big ? 1 : 0.7)
        .sensitive()
    }
}

/// a thin bar, on a faint track: how one row compares with the largest beside it
struct ProportionBar: View {
    let frac: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(2, g.size.width * max(0, min(1, frac))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

struct CategoryListRow: View {
    let symbol: String
    let color: Color
    let name: String
    let value: Double
    /// against the largest category shown
    let frac: Double
    let share: Int?
    var before: Double? = nil
    /// nil: the row opens another page rather than unfolding
    var expanded: Bool? = nil
    @Environment(\.displayCurrency) private var cur
    var body: some View {
        HStack(spacing: AppSpacing.control) {
            IconBadge(symbol: symbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: AppSpacing.icon) {
                HStack(spacing: AppSpacing.icon) {
                    Text(name).lineLimit(1)
                    if let s = share { Text("\(s)%").font(.caption).foregroundStyle(.secondary) }
                    if let b = before { DeltaText(now: value, before: b) }
                    Spacer(minLength: 6)
                    Text(money(value, cur)).fontWeight(.semibold).monospacedDigit().sensitive()
                    if let expanded { Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary).rotationEffect(.degrees(expanded ? 180 : 0)) }
                }
                ProportionBar(frac: frac, color: color)
            }
        }
        .padding(.vertical, AppSpacing.detail)
        .contentShape(Rectangle())
    }
}

struct PayeeRankRow: View {
    let rank: Int
    let name: String
    let value: Double
    let count: Int
    let frac: Double
    let expanded: Bool
    @Environment(\.displayCurrency) private var cur
    var body: some View {
        HStack(spacing: AppSpacing.control) {
            Text("\(rank)").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(rank <= 3 ? Color.jadeInk : Color.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: AppSpacing.icon) {
                HStack(spacing: AppSpacing.icon) {
                    Text(name).lineLimit(1)
                    Text(LS("%@ 次 · 均 %@", count, money(value / Double(max(count, 1)), cur, 0)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1).sensitive()
                    Spacer(minLength: 6)
                    Text(money(value, cur)).fontWeight(.semibold).monospacedDigit().sensitive()
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary).rotationEffect(.degrees(expanded ? 180 : 0))
                }
                ProportionBar(frac: frac, color: .jadeInk)
            }
        }
        .padding(.vertical, AppSpacing.detail)
        .contentShape(Rectangle())
    }
}

struct LiabilityRow: View {
    @Environment(Store.self) var store
    let L: Ledger
    let account: String
    let n: Double
    let currency: String
    let limit: Double?
    let cycle: CardCycle?
    var body: some View {
        let owed = -n
        let today = Day.today()
        VStack(alignment: .leading, spacing: AppSpacing.icon) {
            HStack(spacing: AppSpacing.icon) {
                IconBadge(symbol: store.groupIcon(account).symbol, color: store.groupIcon(account).color, size: 28)
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    Text(acctLabel(account)).lineLimit(1)
                    if let c = cycle {
                        Text(c.settled ? LS("本期已还清 · 下期账单日 %@", c.nextStatement)
                             : c.overdue(today: today) ? LS("本期应还 %@ · 已逾期", money(c.remaining, c.currency))
                             : LS("本期应还 %@ · %@", money(c.remaining, c.currency), daysText(c.due, today: today)))
                            .font(.caption).foregroundStyle(c.overdue(today: today) ? Color.loss : Color.secondary).sensitive()
                    } else if owed < -0.005 {
                        Text(LS("溢缴款")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Amount(n: n, c: currency)
            }
            if let lim = limit, owed > 0 {
                let frac = owed / lim
                HStack(spacing: AppSpacing.icon) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            Capsule().fill(frac >= 0.9 ? Color.chartLoss : frac >= 0.7 ? Color.warn : Color.jade)
                                .frame(width: max(3, g.size.width * min(1, frac)))
                        }
                    }
                    .frame(height: 6)
                    Text(LS("额度 %@ · 已用 %@%", money(lim, currency, 0), String(Int((frac * 100).rounded()))))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).fixedSize().sensitive()
                }
                .padding(.leading, 40)
            }
        }
        .padding(.vertical, AppSpacing.detail)
    }
}
