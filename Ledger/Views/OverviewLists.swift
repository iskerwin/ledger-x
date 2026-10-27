import SwiftUI
import LedgerKit

// The overview's list-style charts: a share bar with a ranked list (and the change from the period
// before), a payee ranking with bars, and each liability's use of its credit limit.

enum OverviewChart {
    static let styleKey = "ledger.overview.chart"
    static let trendKey = "ledger.overview.trend"
}

/// one horizontal bar split by share
struct ShareBar: View {
    let slices: [DonutSlice]
    var body: some View {
        let total = slices.reduce(0) { $0 + $1.value }
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(slices) { s in
                    Rectangle().fill(s.color)
                        .frame(width: max(2, (g.size.width - CGFloat(max(0, slices.count - 1)) * 2) * CGFloat(s.value / max(total, 0.01))))
                }
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
    }
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

struct CategoryListRow: View {
    let color: Color
    let name: String
    let value: Double
    let share: Int?
    let before: Double?
    let expanded: Bool
    @Environment(\.displayCurrency) private var cur
    var body: some View {
        HStack(spacing: AppSpacing.icon) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(name).lineLimit(1)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: AppSpacing.detail) {
                Text(money(value, cur)).monospacedDigit().sensitive()
                if let b = before { DeltaText(now: value, before: b) }
            }
            Text(share.map { "\($0)%" } ?? "").font(.caption).foregroundStyle(.secondary).frame(minWidth: 32, alignment: .trailing)
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary).rotationEffect(.degrees(expanded ? 180 : 0))
        }
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
        HStack(alignment: .center, spacing: AppSpacing.icon) {
            Text("\(rank)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(rank <= 3 ? Color.jadeInk : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                HStack(spacing: AppSpacing.control) {
                    Text(name).lineLimit(1)
                    Spacer()
                    Text(money(value, cur)).monospacedDigit().sensitive()
                }
                HStack(spacing: AppSpacing.icon) {
                    GeometryReader { g in
                        Capsule().fill(Color.jadeSoft).frame(width: max(2, g.size.width * max(0, min(1, frac))), height: 5)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 10)
                    Text(LS("%@ 次 · 均 %@", count, money(value / Double(max(count, 1)), cur, 0)))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: 104, alignment: .trailing).sensitive()
                }
            }
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary).rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .contentShape(Rectangle())
    }
}

/// a liability with how much of its limit is used and, for a card with a billing cycle, the bill
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
                            Capsule().fill(frac >= 0.9 ? Color.loss : frac >= 0.7 ? Color.warn : Color.jade)
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
