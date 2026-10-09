import SwiftUI
import Charts
import LedgerKit

struct OverviewView: View {
    @EnvironmentObject var store: Store
    @State private var path = NavigationPath()
    @AppStorage("ledger.period") private var period = "month"
    @State private var month = Day.ym(Day.today())
    @State private var expanded: Set<String> = []
    @State private var picked: String?
    @State private var reimb: ReimbTarget?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let L = store.L, let D = store.D { content(L, D) } else { ProgressView() }
            }
            .navigationTitle(LS("概览"))
            .toolbar { StandardToolbar() }
            .navigationDestination(for: AccountDest.self) { RegisterView(account: $0.name) }
            .navigationDestination(for: TxDest.self) { TxDetailView(dest: $0) }
            .navigationDestination(for: EditDest.self) { EditTxView(dest: $0) }
            .navigationDestination(for: ErrorsDest.self) { _ in ErrorsView() }
        }
        .onChange(of: store.popToken) { _, _ in path = NavigationPath() }
        .sheet(item: $reimb) { ReimbSheet(target: $0) }
        .task { if store.demoEnv["LEDGER_REIMB"] != nil { reimb = ReimbTarget(link: nil) } }
    }

    private func sum(_ m: [String: Double], _ key: String) -> Double { m.reduce(0.0) { $0 + ($1.key.hasPrefix(key) ? $1.value : 0) } }

    struct Summary {
        var yearMode: Bool
        var key: String
        var label: String
        var months: [String]
        var exp: Double
        var inc: Double
        var prev: Double
        var prevLabel: String
        var avg: Double
        var nw: Double
    }

    private func summary(_ L: Ledger, _ D: Derived) -> Summary {
        let yearMode = period == "year"
        let key = yearMode ? String(month.prefix(4)) : month
        let months: [String] = yearMode ? (1...12).map { String(format: "%@-%02d", key, $0) } : (0..<12).map { Day.addMonth(month, $0 - 11) }
        let today = Day.today()
        var prev = 0.0
        var prevLabel = LS("上月")
        if yearMode {
            let thisYear = key == String(today.prefix(4))
            let lastM = thisYear ? (Int(today.dropFirst(5).prefix(2)) ?? 12) : 12
            let py = String((Int(key) ?? 2000) - 1)
            for i in 1...lastM { prev += D.monthExp[String(format: "%@-%02d", py, i)] ?? 0 }
            prevLabel = thisYear ? LS("去年同期") : LS("%@ 年", py)
        } else {
            prev = D.monthExp[Day.addMonth(month, -1)] ?? 0
        }
        var avg = 0.0
        for m in months.prefix(11) { avg += D.monthExp[m] ?? 0 }
        avg /= 11
        var nw = 0.0
        for (a, cs) in L.final where a.hasPrefix("Assets:") || a.hasPrefix("Liabilities:") {
            for (c, n) in cs { nw += toCNY(L, n, c) ?? 0 }
        }
        return Summary(yearMode: yearMode, key: key, label: yearMode ? LS("%@年", key) : Day.monthLabel(month), months: months,
                       exp: sum(D.monthExp, key), inc: sum(D.monthInc, key), prev: prev, prevLabel: prevLabel, avg: avg, nw: nw)
    }

    private func content(_ L: Ledger, _ D: Derived) -> some View {
        let s = summary(L, D)
        return List {
            heroSection(s)
            chartSection(s, D)
            categorySection(s, D)
            payeeSection(s, L)
            reimbSection(L, D)
            liabilitySection(L)
            checkSection(L)
        }
        .listSectionSpacing(.compact)
        .refreshable { await store.refresh() }
    }

    private func heroSection(_ s: Summary) -> some View {
        let net = s.inc - s.exp
        let rate: Double? = s.inc > 0 ? net / s.inc * 100 : nil
        let delta = s.exp - s.prev
        return Group {
            Section {
                HStack {
                    Picker(LS("周期"), selection: $period) {
                        Text(LS("月")).tag("month")
                        Text(LS("年")).tag("year")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    Spacer()
                    Button { month = s.yearMode ? Day.addMonth(month, -12) : Day.addMonth(month, -1) } label: { Image(systemName: "chevron.left") }
                    Text(s.label).font(.headline).frame(minWidth: 96)
                    Button { month = s.yearMode ? Day.addMonth(month, 12) : Day.addMonth(month, 1) } label: { Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderless)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
            }
            Section {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.yearMode ? LS("本年支出") : LS("本月支出")).font(.subheadline).foregroundStyle(.secondary)
                            Text(money(s.exp)).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                                .contentTransition(.numericText()).sensitive()
                            HStack(spacing: 6) {
                                if s.prev > 0 {
                                    Label(money(abs(delta)), systemImage: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background((delta > 0 ? Color.loss : Color.gain).opacity(0.14), in: Capsule())
                                        .foregroundStyle(delta > 0 ? Color.loss : Color.gain)
                                    Text(LS("较") + s.prevLabel + LS("（") + money(s.prev) + LS("）")).font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text(s.prevLabel + LS("无支出记录")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .sensitive()
                            if !s.yearMode {
                                Text(LS("前 11 个月月均 ") + money(s.avg)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                            }
                        }
                        Divider()
                        HStack(alignment: .top) {
                            Figure(label: LS("收入"), value: money(s.inc, "CNY", 0), color: .gain)
                            Spacer()
                            Figure(label: LS("结余") + (rate.map { String(format: " · %.0f%%", $0) } ?? ""), value: money(net, "CNY", 0), color: net < 0 ? Color.loss : Color.primary)
                            Spacer()
                            Figure(label: LS("净资产"), value: money(s.nw, "CNY", 0), alignment: .trailing)
                        }
                    }
                }
                .cardRow()
            }
        }
    }

    private func monthLabelShort(_ m: String) -> String { String(Int(m.suffix(2)) ?? 0) }

    private func chartSection(_ s: Summary, _ D: Derived) -> some View {
        let months = s.months
        let shown = picked ?? (s.yearMode ? nil : month)
        return Section {
            Chart(months, id: \.self) { m in
                BarMark(x: .value("月", monthLabelShort(m)), y: .value("支出", D.monthExp[m] ?? 0))
                    .foregroundStyle(m == shown ? Color.jade : Color.jadeSoft)
                    .cornerRadius(4)
            }
            .chartYAxis { AxisMarks(position: .trailing) }
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geo[plot].origin.x
                            guard let label: String = proxy.value(atX: x) else { return }
                            let m = months.first { monthLabelShort($0) == label }
                            withAnimation(.easeOut(duration: 0.15)) { picked = (m == picked) ? nil : m }
                        }
                }
            }
            .frame(height: 180)
            .sensitive()
            .padding(.vertical, 6)
            if let p = shown {
                HStack {
                    Text(Day.monthLabel(p) + "  " + money(D.monthExp[p] ?? 0)).monospacedDigit().sensitive()
                    Spacer()
                    if p != month || s.yearMode {
                        Button(LS("查看该月")) { month = p; period = "month"; picked = nil }.buttonStyle(.borderless)
                    }
                }
                .font(.footnote)
            }
        } header: {
            HStack {
                Text(s.yearMode ? LS("%@ 年月度支出", s.key) : LS("近 12 个月支出"))
                Spacer()
                Text(LS("点按柱形查看金额")).textCase(nil)
            }
        }
    }

    private func categorySection(_ s: Summary, _ D: Derived) -> some View {
        let groups = categoryGroups(D, s.key)
        let maxG = max(1, groups.map { $0.total }.max() ?? 1)
        return Section(LS("支出构成")) {
            if groups.isEmpty { Text(s.label + LS("暂无支出记录")).foregroundStyle(.secondary) }
            ForEach(groups, id: \.name) { g in
                Button {
                    if expanded.contains(g.name) { expanded.remove(g.name) } else { expanded.insert(g.name) }
                } label: {
                    CatBar(name: leaf(g.name), sub: acctZH(g.name), value: g.total, frac: g.total / maxG,
                           share: s.exp > 0 && g.total > 0 ? Int((g.total / s.exp * 100).rounded()) : nil, chevron: expanded.contains(g.name))
                }
                .buttonStyle(.plain)
                if expanded.contains(g.name) {
                    ForEach(g.leaves, id: \.0) { leafRow in
                        NavigationLink(value: AccountDest(name: leafRow.0)) {
                            CatBar(name: leaf(leafRow.0), sub: nil, value: leafRow.1, frac: leafRow.1 / maxG, share: nil, chevron: nil).padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func payeeSection(_ s: Summary, _ L: Ledger) -> some View {
        let pay = topPayees(L, s.key)
        if !pay.isEmpty {
            let top = max(pay[0].1, 1)
            Section(LS("商户支出排行")) {
                ForEach(Array(pay.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 12) {
                        Text("\(i + 1)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(i < 3 ? Color.onJade : Color.secondary)
                            .frame(width: 22, height: 22)
                            .background(i < 3 ? Color.jade : Color(.tertiarySystemFill), in: Circle())
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(row.0).lineLimit(1)
                                Spacer()
                                Text(money(row.1)).monospacedDigit().sensitive()
                            }
                            GeometryReader { g in
                                Capsule().fill(Color.jadeSoft).frame(width: max(2, g.size.width * row.1 / top), height: 4)
                            }
                            .frame(height: 4)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func reimbSection(_ L: Ledger, _ D: Derived) -> some View {
        let open = D.openLinks.filter { $0.amount > 0.005 }
        if !D.unclaimed.isEmpty || !open.isEmpty {
            let recv = cny(L, prefix: "Assets:Receivable")
            Section {
                if !D.unclaimed.isEmpty {
                    Button { reimb = ReimbTarget(link: nil) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LS("待报销垫款"))
                                Text(LS("%@ 笔 · 最早 %@ · 点按选择报销明细", D.unclaimed.count, D.unclaimed[0].t.date)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Amount(n: D.unclaimed.reduce(0.0) { $0 + $1.amount })
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(open, id: \.link) { x in
                    Button { reimb = ReimbTarget(link: x.link) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("^" + x.link).font(.subheadline)
                                Text(LS("%@ 笔垫款 · 点按登记回款", x.n)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Amount(n: x.amount, c: x.currency)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text(LS("应收报销款"))
                    Spacer()
                    Text(money(recv)).monospacedDigit().sensitive()
                }
            }
        }
    }

    struct LiabRow { let a: String; let c: String; let n: Double; var id: String { a + "|" + c } }

    private func liabilitySection(_ L: Ledger) -> some View {
        var liab: [LiabRow] = []
        for (a, cs) in L.final where a.hasPrefix("Liabilities:") {
            for (c, n) in cs where abs(n) > 0.005 { liab.append(LiabRow(a: a, c: c, n: n)) }
        }
        liab.sort { $0.n < $1.n }
        let total = liab.reduce(0.0) { $0 + (toCNY(L, $1.n, $1.c) ?? 0) }
        return Section {
            if liab.isEmpty { Text(LS("无负债")).foregroundStyle(.secondary) }
            ForEach(liab, id: \.id) { x in
                NavigationLink(value: AccountDest(name: x.a)) {
                    HStack(spacing: 12) {
                        IconBadge(symbol: AccountKind.of(x.a).symbol, color: AccountKind.of(x.a).color, size: 28)
                        Text(acctLabel(x.a))
                        Spacer()
                        Amount(n: x.n, c: x.c)
                    }
                }
            }
        } header: {
            HStack {
                Text(LS("负债"))
                Spacer()
                Text(money(total)).monospacedDigit().sensitive()
            }
        }
    }

    private func checkSection(_ L: Ledger) -> some View {
        let okCount = L.balanceResults.filter { $0.ok }.count
        return Section(LS("账本校验")) {
            NavigationLink(value: ErrorsDest()) {
                HStack {
                    if L.errors.isEmpty {
                        Label(LS("账本校验通过"), systemImage: "checkmark.seal").foregroundStyle(Color.gain)
                    } else {
                        Label(LS("%@ 项错误", L.errors.count), systemImage: "exclamationmark.triangle").foregroundStyle(Color.loss)
                    }
                    Spacer()
                    Text(LS("%@/%@ 余额断言", okCount, L.balanceResults.count)).font(.caption).foregroundStyle(.secondary)
                }
            }
            CIRow()
        }
    }

    private func cny(_ L: Ledger, prefix: String) -> Double {
        var t = 0.0
        for (a, cs) in L.final where a.hasPrefix(prefix) { for (c, n) in cs { t += toCNY(L, n, c) ?? 0 } }
        return t
    }

    private func stat(_ k: String, _ v: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(k).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(v).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7).sensitive()
        }
        .frame(maxWidth: .infinity)
    }

    struct Group2 { let name: String; var total: Double; var leaves: [(String, Double)] }

    private func categoryGroups(_ D: Derived, _ key: String) -> [Group2] {
        var cm: [String: Double] = [:]
        for (m, cats) in D.monthCat where m.hasPrefix(key) { for (a, v) in cats { cm[a, default: 0] += v } }
        var groups: [String: Group2] = [:]
        for (a, v) in cm {
            let g = catOf(a)
            if groups[g] == nil { groups[g] = Group2(name: g, total: 0, leaves: []) }
            groups[g]!.total += v
            groups[g]!.leaves.append((a, v))
        }
        return groups.values.map { g in var x = g; x.leaves.sort { $0.1 > $1.1 }; return x }.sorted { $0.total > $1.total }
    }

    private func topPayees(_ L: Ledger, _ key: String) -> [(String, Double)] {
        var pay: [String: Double] = [:]
        for t in L.txns where t.date.hasPrefix(key) {
            let c = classify(t, L)
            if c.kind == .expense {
                let k = !t.payee.isEmpty ? t.payee : !t.narration.isEmpty ? t.narration : "—"
                pay[k, default: 0] -= c.amount
            }
        }
        return Array(pay.sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) })
    }
}

struct ErrorsDest: Hashable {}

struct CatBar: View {
    let name: String
    let sub: String?
    let value: Double
    let frac: Double
    let share: Int?
    let chevron: Bool?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(name)
                if let s = sub { Text(s).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(money(value)).monospacedDigit().sensitive()
                if let s = share { Text("\(s)%").font(.caption).foregroundStyle(.secondary).frame(minWidth: 30, alignment: .trailing) }
                if let c = chevron { Image(systemName: c ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary) }
            }
            GeometryReader { g in
                Capsule().fill(Color.jadeSoft).frame(width: max(2, g.size.width * max(0, min(1, frac))), height: 5)
            }
            .frame(height: 5)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

struct CIRow: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let ci = store.ci
        let row = HStack {
            switch ci?.state {
            case .ok?: Label(LS("bean-check 校验通过"), systemImage: "checkmark.circle").foregroundStyle(Color.gain)
            case .fail?: Label(LS("bean-check 校验未通过"), systemImage: "xmark.circle").foregroundStyle(Color.loss)
            case .running?: Label(LS("bean-check 运行中…"), systemImage: "hourglass").foregroundStyle(.secondary)
            case .empty?: Label(LS("暂无 bean-check 运行记录"), systemImage: "circle.dashed").foregroundStyle(.secondary)
            case .noperm?: Label(LS("需为 Token 授予 Actions: Read-only 权限以显示 bean-check 结果"), systemImage: "lock").foregroundStyle(.secondary)
            default: Label(LS("正在获取 bean-check 状态"), systemImage: "circle.dashed").foregroundStyle(.secondary)
            }
            Spacer()
            if let sha = ci?.sha, let head = store.tree?.commit, sha != head { Text(LS("尚未校验最新提交")).font(.caption).foregroundStyle(.secondary) }
        }
        .font(.subheadline)
        if let u = ci?.url.flatMap(URL.init(string:)) { Link(destination: u) { row }.buttonStyle(.plain) } else { row }
    }
}

struct ErrorsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        List {
            if let L = store.L {
                Section(LS("%@ 个文件 · %@ 笔交易 · %@/%@ 余额断言", L.files.count, L.txns.count, L.balanceResults.filter { $0.ok }.count, L.balanceResults.count)) {
                    if L.errors.isEmpty { Label(LS("未发现错误"), systemImage: "checkmark.seal").foregroundStyle(Color.gain) }
                    ForEach(Array(L.errors.enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.msg).font(.subheadline)
                            if let f = e.file { Text("\(f)\(e.line.map { ":\($0)" } ?? "")").font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section { CIRow() }
            }
        }
        .navigationTitle(LS("账本校验"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
