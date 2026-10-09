import SwiftUI
import LedgerKit

struct HoldingsDest: Hashable {}

/// 持仓: everything held at cost (stocks, funds), valued at the latest price
struct HoldingsView: View {
    @EnvironmentObject var store: Store
    @State private var open: Set<String> = []

    var body: some View {
        Group {
            if let L = store.L { page(L) } else { ProgressView() }
        }
        .navigationTitle(LS("持仓"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func cny(_ L: Ledger, _ n: Double, _ c: String) -> Double { toCNY(L, n, c) ?? 0 }

    private func page(_ L: Ledger) -> some View {
        let rows = holdings(L)
        let value = rows.reduce(0.0) { $0 + cny(L, $1.value ?? $1.cost, $1.q) }
        let cost = rows.reduce(0.0) { $0 + cny(L, $1.cost, $1.q) }
        let pxDate = rows.compactMap { $0.px?.date }.max()
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LS("市值合计（折合%@）", L.base)).font(.subheadline).foregroundStyle(.secondary)
                    Text(money(value, L.base)).font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit().sensitive()
                    HStack(spacing: 14) {
                        Text(LS("成本 ") + money(cost, L.base))
                        Text(LS("浮动盈亏 ") + signedMoney(value - cost, L.base) + (cost != 0 ? String(format: LS("（%@%.1f%%）"), value >= cost ? "+" : "", (value - cost) / cost * 100) : ""))
                            .foregroundStyle(value >= cost ? Color.gain : Color.loss)
                    }
                    .font(.caption.monospacedDigit())
                    .sensitive()
                    if let d = pxDate { Text(LS("价格日期 ") + d).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 4)
            }
            Section(LS("持仓明细")) {
                if rows.isEmpty { Text(LS("暂无以成本计价的持仓")).foregroundStyle(.secondary) }
                ForEach(rows) { r in holdingRow(r) }
            }
            incomeSection(L)
            Section {
                EmptyView()
            } footer: {
                Text(LS("市值按账本中最新的 price 指令计算；成本取自买入时记录的 {成本}；卖出时按账户的批次匹配方法（如 FIFO）结转。"))
            }
        }
    }

    @ViewBuilder
    private func holdingRow(_ r: Holding) -> some View {
        Button {
            if open.contains(r.id) { open.remove(r.id) } else { open.insert(r.id) }
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(r.c).font(.headline)
                        Text(acctLabel(r.acct)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(LS("%@ 份 · 均价 %@ %@", fmtNum(r.units, 4), fmtNum(r.avg, 2), r.q) + (r.px.map { LS(" · 现价 %@", fmtNum($0.number, 2)) } ?? LS(" · 无价格")))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(money(r.value ?? r.cost, r.q)).monospacedDigit().sensitive()
                    if let p = r.pnl {
                        Text(signedMoney(p, r.q) + (r.cost != 0 ? String(format: " %@%.1f%%", p >= 0 ? "+" : "", p / r.cost * 100) : ""))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(p >= 0 ? Color.gain : Color.loss)
                            .sensitive()
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open.contains(r.id) {
            ForEach(Array(r.lots.enumerated()), id: \.offset) { pair in
                lotRow(pair.element, r)
            }
            NavigationLink(value: AccountDest(name: r.acct)) {
                Text(LS("查看 %@ 明细", acctLabel(r.acct))).font(.footnote)
            }
        }
    }

    private func lotRow(_ l: Lot, _ r: Holding) -> some View {
        let c = l.cost
        let gain = r.px.map { l.units * ($0.number - (c?.number ?? 0)) }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text((c?.date ?? "") + (c?.label.map { " · " + $0 } ?? "")).font(.caption)
                Text("\(fmtNum(l.units, 4)) × \(fmtNum(c?.number ?? 0, 4)) \(c?.currency ?? "")").font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive()
            }
            Spacer()
            if let g = gain {
                Text(signedMoney(g, r.q)).font(.caption.monospacedDigit()).foregroundStyle(g >= 0 ? Color.gain : Color.loss).sensitive()
            }
        }
        .padding(.leading, 14)
    }

    @ViewBuilder
    private func incomeSection(_ L: Ledger) -> some View {
        let year = String(Day.today().prefix(4))
        let rows = investIncome(L, year)
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.0) { row in
                    NavigationLink(value: AccountDest(name: row.0)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(leaf(row.0))
                                Text(Self.incomeZH[leaf(row.0)] ?? catLabel(row.0)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(money(row.1, L.base)).monospacedDigit().sensitive()
                                Text(LS("累计 ") + money(row.2, L.base)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                            }
                        }
                    }
                }
            } header: {
                Text(LS("投资收入 · %@ 年", year))
            }
        }
    }

    static var incomeZH: [String: String] { ["Gain": LS("已实现收益"), "Dividend": LS("股息"), "Interest": LS("利息"), "StockAward": LS("股票奖励"), "Coupon": LS("票息")] }

    /// Income:Invest:* (or any income account under an "Invest" group): (account, this year, all time)
    private func investIncome(_ L: Ledger, _ year: String) -> [(String, Double, Double)] {
        var ytd: [String: Double] = [:], all: [String: Double] = [:]
        for t in L.txns {
            for p in t.postings where p.units != nil && p.account.hasPrefix("Income:") && p.account.components(separatedBy: ":").contains(where: { $0.hasPrefix("Invest") }) {
                let v = -(toCNY(L, p.units!, p.currency ?? L.base, t.date) ?? 0)
                all[p.account, default: 0] += v
                if t.date.hasPrefix(year) { ytd[p.account, default: 0] += v }
            }
        }
        return all.keys.sorted { abs(all[$0]!) > abs(all[$1]!) }.map { ($0, ytd[$0] ?? 0, all[$0]!) }
    }
}
