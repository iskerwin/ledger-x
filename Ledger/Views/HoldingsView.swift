import SwiftUI
import LedgerKit

struct HoldingsDest: Hashable {}

/// 持仓: everything held at cost (stocks, funds), valued at the latest price
struct HoldingsView: View {
    @EnvironmentObject var store: Store
    @State private var open: Set<String> = []
    @State private var pricing = false

    var body: some View {
        Group {
            if let L = store.L { page(L) } else { ProgressView() }
        }
        .navigationTitle(LS("持仓"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { pricing = true } label: { Label(LS("更新价格"), systemImage: "tag") }
            }
        }
        .sheet(isPresented: $pricing) { PriceUpdateSheet() }
        .task { if store.demoEnv["LEDGER_PRICES"] != nil { pricing = true } }
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


// MARK: - 更新价格

/// one row of the price sheet: a commodity or currency and the currency it is quoted in
struct PriceItem: Identifiable, Hashable {
    var id: String { c + "/" + q }
    let c: String
    let q: String
    let last: Double?
    let date: String?
}

/// write price directives for the held commodities and foreign currencies, all at once
struct PriceUpdateSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var date = Day.today()
    @State private var values: [String: String] = [:]
    @FocusState private var focus: String?

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L { form(L) } else { ProgressView() }
            }
            .keyboardDone()
            .navigationTitle(LS("更新价格"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LS("保存")) { save() }.fontWeight(.semibold).disabled(lines().isEmpty)
                }
            }
        }
    }

    static func items(_ L: Ledger) -> [PriceItem] {
        var seen = Set<String>()
        var out: [PriceItem] = []
        func add(_ c: String, _ q: String) {
            guard c != q, seen.insert(c + "/" + q).inserted else { return }
            let p = latestPrice(L, c, q)
            out.append(PriceItem(c: c, q: q, last: p?.number, date: p?.date))
        }
        for h in holdings(L) { add(h.c, h.q) }
        // foreign currencies held in assets or liabilities
        for (a, cs) in L.final.sorted(by: { $0.key < $1.key }) where a.hasPrefix("Assets") || a.hasPrefix("Liabilities") {
            for (c, n) in cs.sorted(by: { $0.key < $1.key }) where abs(n) > 0.005 && c.count == 3 && c.uppercased() == c && !holdings(L).contains(where: { $0.c == c }) {
                add(c, L.base)
            }
        }
        // anything else that already has prices
        for p in L.prices where !seen.contains(p.currency.map { $0 + "/" + (p.quote ?? "") } ?? "") {
            if let c = p.currency, let q = p.quote, out.count < 40 { add(c, q) }
        }
        return out
    }

    private func form(_ L: Ledger) -> some View {
        let items = Self.items(L)
        return Form {
            Section {
                DatePicker(LS("价格日期"), selection: dateBinding($date), displayedComponents: .date)
            } footer: {
                Text(LS("只会写入填写了新价格的项目，每项一条 price 指令。"))
            }
            Section {
                if items.isEmpty { Text(LS("没有需要报价的证券或外币")).foregroundStyle(.secondary) }
                ForEach(items) { it in
                    let days = it.date.flatMap { d in Day.date(d).map { Int(Date().timeIntervalSince($0) / 86400) } }
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(it.c).font(.body.weight(.semibold))
                                Text("/ " + it.q).font(.caption).foregroundStyle(.secondary)
                                if let d = days, d > 7 { Tag(text: LS("已过期 %@ 天", d), warn: true) }
                                if it.last == nil { Tag(text: LS("无价格"), warn: true) }
                            }
                            if let l = it.last, let d = it.date {
                                Text(LS("最新 %@ · %@", fmtNum(l, l < 10 ? 4 : 2), d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                            }
                        }
                        Spacer()
                        TextField(it.last.map { fmtNum($0, $0 < 10 ? 4 : 2) } ?? "0.00", text: Binding(get: { values[it.id] ?? "" }, set: { values[it.id] = $0 }))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: 130)
                            .focused($focus, equals: it.id)
                    }
                }
            } header: {
                Text(LS("证券与外币"))
            }
            if !lines().isEmpty {
                Section(LS("将写入")) { MonoText(text: lines().joined(separator: "\n")) }
            }
        }
    }

    private func lines() -> [String] {
        guard let L = store.L else { return [] }
        return Self.items(L).compactMap { it in
            guard let v = evalAmount(values[it.id] ?? ""), v > 0 else { return nil }
            return "\(date) price \(it.c)" + String(repeating: " ", count: max(1, 26 - it.c.count)) + jsNumberString(roundTo(v, 6)) + " " + it.q
        }
    }

    private func save() {
        let ls = lines()
        guard !ls.isEmpty, let ops = store.makeOps(ls.joined(separator: "\n"), single: false) else { return }
        dismiss()
        Task { await store.commit(ops, word: LS("已更新 %@ 项价格", ls.count)) }
    }
}
