import SwiftUI
import LedgerKit

/// 账户 with 卡面: an account as a bank card in its group's stack (`CardStack`). Its top strip, what a card behind
/// shows, is its name and its balance (valued as chosen, 币种与换算, as the group's total adds them); under it how
/// it stands: a credit card its bill, any other account when it was last checked, the last 30 days and this month's
/// money in and out. `still` for one only drawn (its place kept in the stack): no menu, not read out.
struct AccountCard: View {
    @Environment(Store.self) var store
    let row: AccountsView.Row
    let failing: Bool
    /// its bill, for a credit card
    let cycle: CardCycle?
    var still = false

    var body: some View {
        let a = row.account
        let title = store.displayName(a).flatMap { $0.isEmpty ? nil : $0 } ?? acctDisplay(a)
        FaceCard(subject: .account(a), title: title, tint: store.groupIcon(a).color,
                 preview: still ? store.faceStyles[a] ?? FaceStyle() : nil,
                 holdsCard: a.hasPrefix("Assets:Bank:") || cycle != nil,
                 identifier: "account.card." + a, real: true) { ink in
            AccountCardContent(row: row, title: title, failing: failing, cycle: cycle, ink: ink)
        }
        .grayscale(row.closed ? 1 : 0)
        // a card's top edge lifted off the one behind it
        .shadow(color: .black.opacity(0.14), radius: 6, y: -2)
        .accessibilityHidden(still)
    }
}

private struct AccountCardContent: View {
    @Environment(Store.self) var store
    let row: AccountsView.Row
    let title: String
    let failing: Bool
    let cycle: CardCycle?
    let ink: Color

    var body: some View {
        let a = row.account
        let base = store.L?.base ?? "CNY"
        let valued = row.shown.byCurrency(base: base)
        let tail = store.cardTail(a)
        let notes = [row.closed ? LS("已关闭") : nil, isExcluded(a, store.netWorthExclude) ? LS("不计入净资产") : nil].compactMap { $0 }
        VStack(alignment: .leading, spacing: AppSpacing.control) {
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                HStack(spacing: AppSpacing.icon) {
                    Text(title + (tail.map { " •••• " + $0 } ?? "")).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if failing { Image(systemName: "exclamationmark.circle.fill").font(.caption) }
                    Spacer(minLength: AppSpacing.icon)
                    Text(valued.isEmpty ? money(0, base) : valued.map { unitText($0.amount, $0.currency) }.joined(separator: " · "))
                        .font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).sensitive()
                }
                Text(([a] + notes).joined(separator: " · ")).font(.caption).opacity(0.8).lineLimit(1)
            }
            // the rest at the foot of a card as tall as a bank card
            Spacer(minLength: 0)
            if let c = cycle { bill(c) } else { standing(valued) }
        }
    }

    /// a credit card: what is still to pay on its bill, against what was paid, and when it is due
    private func bill(_ c: CardCycle) -> some View {
        let look = CardStatusLook(c, today: Day.today())
        let paid = c.statementAmount > 0.005 ? min(1, max(0, c.paid / c.statementAmount)) : 1
        return VStack(alignment: .leading, spacing: AppSpacing.control) {
            HStack(alignment: .bottom, spacing: AppSpacing.control) {
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    Text(LS("剩余应还")).font(.caption).opacity(0.8)
                    Text(money(c.remaining, c.currency)).font(.headline).monospacedDigit().lineLimit(1).sensitive()
                }
                Spacer(minLength: 0)
                Label(look.text, systemImage: look.icon).labelStyle(ControlLabelStyle())
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, AppSpacing.icon).padding(.vertical, 3)
                    .background(ink.opacity(0.18), in: Capsule())
            }
            GeometryReader { geo in
                Capsule().fill(ink.opacity(0.25))
                    .overlay(alignment: .leading) { Capsule().fill(ink).frame(width: geo.size.width * paid) }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
            Text(LS("还款日 %@", (c.dueEstimated ? "≈ " : "") + LS("%@月%@日", String(Int(c.due.dropFirst(5).prefix(2)) ?? 0), String(Int(c.due.suffix(2)) ?? 0))))
                .font(.caption.weight(.semibold)).lineLimit(1)
        }
    }

    /// any other account: what it holds as booked when that is not the balance on top, when it was last checked, the
    /// last 30 days, this month's money in and out
    private func standing(_ valued: [CurrencyAmount]) -> some View {
        let main = row.balances.first?.0 ?? store.L?.base ?? "CNY"
        let glance = store.L.map { accountGlance($0, row.account, currency: main) }
        let same = Set(valued.map(\.currency)) == Set(row.balances.map(\.0))
        return VStack(alignment: .leading, spacing: AppSpacing.control) {
            if !same {
                FlowLayout(spacing: AppSpacing.detail + 2) {
                    ForEach(row.balances, id: \.0) { b in
                        Text(money(b.1, b.0)).font(.caption.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, AppSpacing.icon).padding(.vertical, 3)
                            .background(ink.opacity(0.18), in: Capsule())
                            .sensitive()
                    }
                }
            }
            HStack(alignment: .bottom, spacing: AppSpacing.control) {
                CheckPill(lastCheck: glance?.lastCheck, ink: ink, failing: failing)
                Spacer(minLength: 0)
                // its shape gives the amounts away: hidden with them
                if let g = glance, !KitPrivacy.masked { TrendLine(values: g.trend, ink: ink).frame(width: 96, height: 32) }
            }
            if let g = glance {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppSpacing.content) { flow(g) }
                    VStack(alignment: .leading, spacing: AppSpacing.detail) { flow(g) }
                }
                .font(.caption.weight(.semibold)).monospacedDigit()
            }
        }
    }

    @ViewBuilder private func flow(_ g: AccountGlance) -> some View {
        Text(LS("本月流入 %@", money(g.inflow, g.currency))).lineLimit(1).sensitive()
        Text(LS("本月流出 %@", money(g.outflow, g.currency))).lineLimit(1).sensitive()
    }
}
