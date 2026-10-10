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
    var body: some View {
        let d = now - before
        let big = before > 0 ? abs(d) / before >= 0.2 && abs(d) >= 1 : now > 0
        Group {
            if before <= 0.005 && now > 0.005 {
                Text(LS("新增"))
            } else if abs(d) < 0.5 {
                Text(LS("持平"))
            } else {
                Text((d > 0 ? "↑ " : "↓ ") + money(abs(d), "CNY", 0))
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
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(name).lineLimit(1)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(money(value)).monospacedDigit().sensitive()
                if let b = before { DeltaText(now: value, before: b) }
            }
            Text(share.map { "\($0)%" } ?? "").font(.caption).foregroundStyle(.secondary).frame(minWidth: 32, alignment: .trailing)
            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
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
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(rank)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(rank <= 3 ? Color.jade : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name).lineLimit(1)
                    Spacer()
                    Text(money(value)).monospacedDigit().sensitive()
                }
                HStack(spacing: 8) {
                    GeometryReader { g in
                        Capsule().fill(Color.jadeSoft).frame(width: max(2, g.size.width * max(0, min(1, frac))), height: 5)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 10)
                    Text(LS("%@ 次 · 均 %@", count, money(value / Double(max(count, 1)), "CNY", 0)))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).fixedSize().sensitive()
                }
            }
            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// a liability with how much of its limit is used and, for a card with a billing cycle, the bill
struct LiabilityRow: View {
    let L: Ledger
    let account: String
    let n: Double
    let currency: String
    let limit: Double?
    let cycle: CardCycle?
    var body: some View {
        let owed = -n
        let today = Day.today()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                IconBadge(symbol: AccountKind.of(account).symbol, color: AccountKind.of(account).color, size: 28)
                VStack(alignment: .leading, spacing: 2) {
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
                HStack(spacing: 8) {
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
        .padding(.vertical, 2)
    }
}
