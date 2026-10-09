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
            .navigationTitle("概览")
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
        var prevLabel = "上月"
        if yearMode {
            let thisYear = key == String(today.prefix(4))
            let lastM = thisYear ? (Int(today.dropFirst(5).prefix(2)) ?? 12) : 12
            let py = String((Int(key) ?? 2000) - 1)
            for i in 1...lastM { prev += D.monthExp[String(format: "%@-%02d", py, i)] ?? 0 }
            prevLabel = thisYear ? "去年同期" : "\(py) 年"
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
        return Summary(yearMode: yearMode, key: key, label: yearMode ? "\(key)年" : Day.monthLabel(month), months: months,
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
        .refreshable { await store.refresh() }
    }

    private func heroSection(_ s: Summary) -> some View {
        let net = s.inc - s.exp
        let rate: Int? = s.inc > 0 ? Int((net / s.inc * 100).rounded()) : nil
        return Section {
            HStack {
                Picker("周期", selection: $period) {
                    Text("月").tag("month")
                    Text("年").tag("year")
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
                Spacer()
                Button { month = s.yearMode ? Day.addMonth(month, -12) : Day.addMonth(month, -1) } label: { Image(systemName: "chevron.left") }
                Text(s.label).font(.headline).frame(minWidth: 96)
                Button { month = s.yearMode ? Day.addMonth(month, 12) : Day.addMonth(month, 1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 6) {
                Text(s.yearMode ? "本年支出" : "本月支出").font(.subheadline).foregroundStyle(.secondary)
                Text(money(s.exp)).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit().sensitive()
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.prevLabel + " " + money(s.prev) + "，" + (s.exp > s.prev ? "多花 " : "少花 ") + money(abs(s.exp - s.prev)))
                    if !s.yearMode { Text("近 11 个月平均 " + money(s.avg)) }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .sensitive()
            }
            .padding(.vertical, 4)
            HStack(spacing: 0) {
                stat("收入", money(s.inc, "CNY", 0), color: Color.jade)
                Divider()
                stat("结余" + (rate.map { " · \($0)%" } ?? ""), money(net, "CNY", 0), color: net < 0 ? Color.loss : Color.primary)
                Divider()
                stat("净资产", money(s.nw, "CNY", 0), color: Color.primary)
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
                        Button("看这个月") { month = p; period = "month"; picked = nil }.buttonStyle(.borderless)
                    }
                }
                .font(.footnote)
            }
        } header: {
            HStack {
                Text(s.yearMode ? "\(s.key) 年每月支出" : "近 12 个月支出")
                Spacer()
                Text("点柱子看金额").textCase(nil)
            }
        }
    }

    private func categorySection(_ s: Summary, _ D: Derived) -> some View {
        let groups = categoryGroups(D, s.key)
        let maxG = max(1, groups.map { $0.total }.max() ?? 1)
        return Section("分类") {
            if groups.isEmpty { Text(s.label + "还没有支出").foregroundStyle(.secondary) }
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
            Section("花得最多的商户") {
                ForEach(pay, id: \.0) { row in
                    HStack {
                        Text(row.0)
                        Spacer()
                        Text(money(row.1)).monospacedDigit().sensitive()
                    }
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
                                Text("未报销的垫付")
                                Text("\(D.unclaimed.count) 笔，最早 \(D.unclaimed[0].t.date) · 点击选择要报销的交易").font(.caption).foregroundStyle(.secondary)
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
                                Text("\(x.n) 笔垫付 · 点击记到账").font(.caption).foregroundStyle(.secondary)
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
                    Text("待报销")
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
            if liab.isEmpty { Text("没有负债").foregroundStyle(.secondary) }
            ForEach(liab, id: \.id) { x in
                NavigationLink(value: AccountDest(name: x.a)) {
                    HStack {
                        Text(acctLabel(x.a))
                        Spacer()
                        Amount(n: x.n, c: x.c)
                    }
                }
            }
        } header: {
            HStack {
                Text("负债")
                Spacer()
                Text(money(total)).monospacedDigit().sensitive()
            }
        }
    }

    private func checkSection(_ L: Ledger) -> some View {
        let okCount = L.balanceResults.filter { $0.ok }.count
        return Section("账本检查") {
            NavigationLink(value: ErrorsDest()) {
                HStack {
                    if L.errors.isEmpty {
                        Label("应用内检查全部通过", systemImage: "checkmark.seal").foregroundStyle(Color.jade)
                    } else {
                        Label("\(L.errors.count) 个问题", systemImage: "exclamationmark.triangle").foregroundStyle(Color.loss)
                    }
                    Spacer()
                    Text("\(okCount)/\(L.balanceResults.count) 余额断言").font(.caption).foregroundStyle(.secondary)
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
            case .ok?: Label("官方 bean-check 通过", systemImage: "checkmark.circle").foregroundStyle(Color.jade)
            case .fail?: Label("官方 bean-check 未通过", systemImage: "xmark.circle").foregroundStyle(Color.loss)
            case .running?: Label("官方 bean-check 运行中…", systemImage: "hourglass").foregroundStyle(.secondary)
            case .empty?: Label("还没有 bean-check 记录", systemImage: "circle.dashed").foregroundStyle(.secondary)
            case .noperm?: Label("Token 需要加「Actions: Read-only」才能看到 bean-check", systemImage: "lock").foregroundStyle(.secondary)
            default: Label("bean-check 状态读取中", systemImage: "circle.dashed").foregroundStyle(.secondary)
            }
            Spacer()
            if let sha = ci?.sha, let head = store.tree?.commit, sha != head { Text("还没检查到最新提交").font(.caption).foregroundStyle(.secondary) }
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
                Section("\(L.files.count) 个文件 · \(L.txns.count) 笔交易 · \(L.balanceResults.filter { $0.ok }.count)/\(L.balanceResults.count) 余额断言") {
                    if L.errors.isEmpty { Label("没有发现问题", systemImage: "checkmark.seal").foregroundStyle(Color.jade) }
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
        .navigationTitle("账本检查")
        .navigationBarTitleDisplayMode(.inline)
    }
}
