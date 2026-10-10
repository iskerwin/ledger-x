import SwiftUI
import LedgerKit

struct SubscriptionsDest: Hashable {}

/// "3 天后" / "今天" / "已过 2 天"
func daysText(_ date: String, today: String = Day.today()) -> String {
    guard let a = Day.date(today), let b = Day.date(date) else { return date }
    let n = Int((b.timeIntervalSince(a) / 86400).rounded())
    switch n {
    case 0: return LS("今天")
    case 1: return LS("明天")
    case 2...: return LS("%@ 天后", n)
    default: return LS("已过 %@ 天", -n)
    }
}

// MARK: - store helpers

extension Store {
    /// subscriptions and candidates for the current ledger, computed once per rebuild
    var subs: [Subscription] {
        guard let L = L else { return [] }
        if let c = Store.subCache, c.0 == version { return c.1 }
        let s = subscriptions(L)
        Store.subCache = (version, s)
        return s
    }
    static var subCache: (Int, [Subscription])?

    var subCandidates: [SubCandidate] {
        guard let L = L else { return [] }
        let ignored = Set(Prefs.get(pk("sub.ignored"), [String]()))
        if let c = Store.candCache, c.0 == version { return c.1.filter { !ignored.contains($0.id) } }
        let s = subscriptionCandidates(L, subs: subs)
        Store.candCache = (version, s)
        return s.filter { !ignored.contains($0.id) }
    }
    static var candCache: (Int, [SubCandidate])?

    func ignoreCandidate(_ c: SubCandidate) {
        var x = Prefs.get(pk("sub.ignored"), [String]())
        x.append(c.id)
        Prefs.set(pk("sub.ignored"), x)
        Store.candCache = nil
        objectWillChange.send()
    }

    /// write the charge as a transaction carrying the subscription's link
    func recordSubscription(_ s: Subscription, date: String) async {
        guard !s.account.isEmpty, !s.funding.isEmpty else {
            show(LS("请先为「%@」设置支出科目和付款账户", s.name))
            return
        }
        let q = quoted
        let payee = s.payee.isEmpty ? s.name : s.payee
        let narration = s.payee.isEmpty || s.payee == s.name ? "" : s.name
        let text = """
        \(date) * \(q(payee)) \(q(narration)) ^\(s.link)
          \(s.account)  \(toFixed(s.amount, 2)) \(s.currency)
          \(s.funding)
        """
        guard let ops = makeOps(alignText(text), extra: OpExtra(label: LS("订阅扣费：%@ %@", s.name, money(s.amount, s.currency))), single: true) else { return }
        await commit(ops, word: LS("已记录 %@", s.name))
    }

    /// add `^link` to the header of each transaction
    func linkOps(_ txns: [Entry], link: String, label: String?) async -> [Op] {
        var ops: [Op] = []
        var files: [String: [String]] = [:]
        for e in txns where !e.links.contains(link) {
            if files[e.file] == nil { files[e.file] = (try? await fileText(e.file))?.components(separatedBy: "\n") ?? [] }
            guard let lines = files[e.file], e.startLine < lines.count else { continue }
            var op = Op(kind: .link, path: e.file)
            op.headerLine = e.startLine + 1
            op.header = lines[e.startLine]
            op.add = " ^" + link
            op.link = link
            op.date = e.date
            if ops.isEmpty, let l = label { op.label = l } else { op.silent = true }
            ops.append(op)
        }
        return ops
    }

    /// take `^link` off a transaction
    func unlinkOp(_ e: Entry, link: String) -> Op? {
        var lines = e.src.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }
        let words = lines[0].components(separatedBy: " ").filter { $0 != "^" + link }
        lines[0] = words.joined(separator: " ")
        var op = Op(kind: .replace, path: e.file)
        op.old = e.src
        op.text = lines.joined(separator: "\n")
        op.date = e.date
        op.label = LS("取消订阅关联：%@ %@", e.date, e.payee)
        return op
    }

    /// new transactions that match a subscription get its link (returns the names linked)
    func autoLinkSubscriptions(_ ops: [Op]) -> ([Op], [String]) {
        guard let L = L, !subs.isEmpty else { return (ops, []) }
        var names: [String] = []
        let out = ops.map { op -> Op in
            guard op.kind == .insert, let text = op.text else { return op }
            let blocks = text.components(separatedBy: "\n\n").map { block -> String in
                let r = checkText(block, L)
                guard r.entries.count == 1, let t = r.entries.first, t.type == .txn, !t.links.contains(where: { $0.hasPrefix("sub-") }),
                      t.meta["subscription"] == nil,
                      let exp = t.postings.first(where: { $0.account.hasPrefix("Expenses:") }), let u = exp.units, u > 0, let c = exp.currency,
                      let s = matchSubscription(payee: t.payee.isEmpty ? t.narration : t.payee, account: exp.account, amount: u, currency: c, subs)
                else { return block }
                var lines = block.components(separatedBy: "\n")
                guard let i = lines.firstIndex(where: { $0.hasPrefix(t.date) }) else { return block }
                lines[i] = trimTrailingSpaces(lines[i]) + " ^" + s.link
                names.append(s.name)
                return lines.joined(separator: "\n")
            }
            var o = op
            o.text = blocks.joined(separator: "\n\n")
            return o
        }
        return (out, names)
    }

    /// after saving: a new transaction that fits a regular pattern → offer to track it
    func suggestSubscription(after ops: [Op]) {
        guard let L = L else { return }
        var keys = Set<String>()
        for op in ops where op.kind == .insert {
            guard let text = op.text else { continue }
            for t in checkText(text, L).entries where t.type == .txn { keys.insert(t.date + "|" + (t.payee.isEmpty ? t.narration : t.payee)) }
        }
        guard !keys.isEmpty, keys.count <= 3 else { return }
        guard let c = subCandidates.first(where: { c in c.txns.contains { keys.contains($0.date + "|" + c.payee) } }) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            show(LS("「%@」看起来是%@扣费", c.payee, c.period.name), action: LS("加入订阅")) { @MainActor [weak self] in self?.subSuggestion = c }
        }
    }
}

private func trimTrailingSpaces(_ s: String) -> String {
    var x = s
    while x.last == " " || x.last == "\t" { x.removeLast() }
    return x
}

// MARK: - overview section

struct SubscriptionOverviewSection: View {
    @EnvironmentObject var store: Store
    let L: Ledger

    var body: some View {
        let all = store.subs
        let subs = all.filter { $0.status == .active }
        let due = subscriptionsDue(L, subs: all)
        let today = Day.today()
        let monthly = subs.reduce(0.0) { $0 + (toCNY(L, $1.monthly, $1.currency) ?? 0) }
        let upcoming = subs.map { ($0, $0.due(onOrAfter: today)) }.min { $0.1 < $1.1 }
        let cands = store.subCandidates
        let alerts = all.reduce(0) { $0 + subscriptionAlerts($1, today: today).count }
        Section {
            ForEach(due) { d in SubDueRow(due: d) }
            NavigationLink(value: SubscriptionsDest()) {
                HStack(spacing: 12) {
                    IconBadge(symbol: "repeat", color: .purple, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subs.isEmpty ? LS("订阅管理") : LS("%@ 个订阅 · 月均 %@", subs.count, money(monthly, L.base, 0)))
                            .sensitive()
                        if let u = upcoming {
                            Text(LS("下次：%@ · %@", u.0.name, daysText(u.1, today: today))).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(LS("记录周期扣费，到期提醒并一键入账")).font(.caption).foregroundStyle(.secondary)
                        }
                        if !cands.isEmpty || alerts > 0 {
                            Text([cands.isEmpty ? nil : LS("发现 %@ 个可能的订阅", cands.count), alerts > 0 ? LS("%@ 项需要留意", alerts) : nil]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Color.warn)
                        }
                    }
                }
            }
        } header: {
            Text(LS("订阅"))
        }
    }
}

struct SubDueRow: View {
    @EnvironmentObject var store: Store
    let due: SubDue
    @State private var busy = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(due.sub.name)
                Text(LS("%@ 应扣费 · 未入账", due.date)).font(.caption).foregroundStyle(Color.warn)
            }
            Spacer()
            Text(money(due.sub.amount, due.sub.currency)).monospacedDigit().sensitive()
            Button {
                busy = true
                Task { await store.recordSubscription(due.sub, date: due.date); busy = false }
            } label: {
                Text(LS("记一笔")).font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(busy)
        }
    }
}

// MARK: - list

struct SubscriptionsView: View {
    @EnvironmentObject var store: Store
    @State private var editing: SubDraft?
    @State private var demoDetail: String?

    var body: some View {
        Group {
            if let L = store.L { list(L) } else { ProgressView() }
        }
        .navigationTitle(LS("订阅管理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = SubDraft(currency: store.L?.base ?? "CNY") } label: { Image(systemName: "plus") }
                    .accessibilityLabel(LS("添加订阅"))
            }
        }
        .sheet(item: $editing) { SubEditSheet(draft: $0) }
        .navigationDestination(item: $demoDetail) { SubscriptionDetailView(name: $0) }
        .task {
            if let n = store.demoEnv["LEDGER_SUB_DETAIL"] { demoDetail = n; return }
            if store.demoEnv["LEDGER_SUB_EDIT"] != nil, let c = store.subCandidates.first { editing = SubDraft(c) }
            else if store.demoEnv["LEDGER_SUB_EDIT"] != nil, let s = store.subs.first { editing = SubDraft(s, mode: .change) }
        }
    }

    private func list(_ L: Ledger) -> some View {
        let all = store.subs
        let today = Day.today()
        let active = all.filter { $0.status == .active }.sorted { $0.due(onOrAfter: today) < $1.due(onOrAfter: today) }
        let inactive = all.filter { $0.status != .active }
        let due = subscriptionsDue(L, today: today, subs: all)
        let monthly = active.reduce(0.0) { $0 + (toCNY(L, $1.monthly, $1.currency) ?? 0) }
        let year = String(today.prefix(4))
        let paidThisYear = all.reduce(0.0) { $0 + (toCNY(L, $1.paid(in: year), $1.currency) ?? 0) }
        let cands = store.subCandidates
        return List {
            Section {
                Card {
                    HStack(alignment: .top) {
                        Figure(label: LS("月均"), value: money(monthly, L.base))
                        Spacer()
                        Figure(label: LS("%@ 年已付", year), value: money(paidThisYear, L.base, 0))
                        Spacer()
                        Figure(label: LS("订阅中"), value: "\(active.count)", alignment: .trailing)
                    }
                }
                .cardRow()
            }
            if !due.isEmpty {
                Section(LS("待记账")) { ForEach(due) { SubDueRow(due: $0) } }
            }
            if !cands.isEmpty {
                Section {
                    ForEach(cands) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.payee)
                                Text(LS("%@ · %@ 笔 · %@ 起", c.period.name, c.count, c.first)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(money(c.amount, c.currency)).monospacedDigit().sensitive()
                            Button(LS("加入")) { editing = SubDraft(c) }.buttonStyle(.bordered).controlSize(.small)
                        }
                        .swipeActions { Button(LS("忽略")) { store.ignoreCandidate(c) }.tint(.gray) }
                    }
                } header: {
                    Text(LS("发现可能的订阅"))
                } footer: {
                    Text(LS("同一商户按固定周期扣费的交易。加入后会把这些交易关联到订阅；左滑可忽略。"))
                }
            }
            Section {
                if active.isEmpty { Text(LS("还没有订阅。点右上角 +，或在交易详情里选择「加入订阅管理」。")).foregroundStyle(.secondary) }
                ForEach(active) { s in row(s, L, today) }
            } header: {
                Text(LS("订阅中"))
            }
            if !inactive.isEmpty {
                Section(LS("已暂停 / 已取消")) { ForEach(inactive) { s in row(s, L, today) } }
            }
            statsSection(all, L, today)
        }
        .listSectionSpacing(.compact)
    }

    private func row(_ s: Subscription, _ L: Ledger, _ today: String) -> some View {
        let next = s.due(onOrAfter: today)
        let alerts = subscriptionAlerts(s, today: today)
        return NavigationLink { SubscriptionDetailView(name: s.name) } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: s.status == .active ? "repeat" : s.status == .paused ? "pause" : "xmark", color: s.status == .active ? .purple : .gray, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(s.name)
                        if !alerts.isEmpty { Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(Color.warn) }
                    }
                    Group {
                        if s.status == .active {
                            Text(s.period.name + " · " + LS("下次 %@（%@）", next, daysText(next, today: today)))
                        } else {
                            Text(s.period.name + " · " + s.status.name + " · " + s.statusDate)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text(LS("已扣 %@ 期 · 累计 %@", s.charges.count, money(s.totalPaid, s.currency, 0))).font(.caption2).foregroundStyle(.secondary).sensitive()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(money(s.amount, s.currency)).monospacedDigit()
                    if s.period != .monthly {
                        Text(LS("月均 %@", money(s.monthly, s.currency))).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .sensitive()
            }
        }
        .swipeActions(edge: .leading) {
            if s.status == .active {
                Button(LS("记一笔")) { Task { await store.recordSubscription(s, date: s.due(onOrBefore: today) ?? today) } }.tint(Color.jade)
            }
        }
    }

    @ViewBuilder
    private func statsSection(_ all: [Subscription], _ L: Ledger, _ today: String) -> some View {
        let active = all.filter { $0.status == .active }
        if active.count >= 2 {
            let rows = byCategory(active, L)
            let total = max(rows.reduce(0) { $0 + $1.value }, 1)
            let y = Int(today.prefix(4)) ?? 2026
            let years = (0..<3).map { String(y - $0) }
            Section(LS("统计")) {
                ForEach(rows, id: \.key) { r in
                    CatBar(name: acctZH(r.key) ?? leaf(r.key), sub: nil, value: r.value, frac: r.value / total,
                           share: Int((r.value / total * 100).rounded()), chevron: nil)
                }
                ForEach(years, id: \.self) { yr in
                    LabeledContent(LS("%@ 年订阅支出", yr), value: money(all.reduce(0.0) { $0 + (toCNY(L, $1.paid(in: yr), $1.currency) ?? 0) }, L.base, 0))
                        .sensitive()
                }
            }
        }
    }
}

private func byCategory(_ subs: [Subscription], _ L: Ledger) -> [(key: String, value: Double)] {
    var m: [String: Double] = [:]
    for s in subs { m[catOf(s.account), default: 0] += toCNY(L, s.monthly, s.currency) ?? 0 }
    return m.sorted { $0.value > $1.value }.map { (key: $0.key, value: $0.value) }
}

extension SubStatus: Identifiable { public var id: String { rawValue } }

// MARK: - detail

struct SubscriptionDetailView: View {
    @EnvironmentObject var store: Store
    let name: String
    @State private var editing: SubDraft?
    @State private var stateChange: SubStatus?
    @State private var linking = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let s = store.subs.first(where: { $0.name == name }) { content(s) } else { Text(LS("该订阅已不存在")).foregroundStyle(.secondary) }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { SubEditSheet(draft: $0) }
        .sheet(item: $stateChange) { st in SubStateSheet(name: name, status: st) }
        .sheet(isPresented: $linking) { SubLinkSheet(name: name) }
    }

    private func content(_ s: Subscription) -> some View {
        let today = Day.today()
        let next = s.due(onOrAfter: today)
        let alerts = subscriptionAlerts(s, today: today)
        return List {
            Section {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(money(s.amount, s.currency) + " / " + s.period.name).font(.title3.weight(.semibold)).sensitive()
                                Text(s.status == .active ? LS("下次扣费 %@（%@）", next, daysText(next, today: today)) : s.status.name + " · " + s.statusDate)
                                    .font(.subheadline).foregroundStyle(s.status == .active ? Color.secondary : Color.warn)
                            }
                            Spacer()
                        }
                        HStack(alignment: .top) {
                            Figure(label: LS("累计已付"), value: money(s.totalPaid, s.currency, 0))
                            Spacer()
                            Figure(label: LS("今年"), value: money(s.paid(in: String(today.prefix(4))), s.currency, 0))
                            Spacer()
                            Figure(label: LS("扣费次数"), value: "\(s.charges.count)", alignment: .trailing)
                        }
                    }
                }
                .cardRow()
            }
            if !alerts.isEmpty {
                Section(LS("需要留意")) {
                    ForEach(alerts) { a in alertRow(a, s) }
                }
            }
            Section {
                if s.status == .active {
                    Button { Task { await store.recordSubscription(s, date: s.due(onOrBefore: today) ?? today) } } label: { Label(LS("记一笔扣费"), systemImage: "plus.circle") }
                    Button { editing = SubDraft(s, mode: .change) } label: { Label(LS("调价或更改"), systemImage: "slider.horizontal.3") }
                    Button { stateChange = .paused } label: { Label(LS("暂停"), systemImage: "pause.circle") }
                    Button(role: .destructive) { stateChange = .cancelled } label: { Label(LS("取消订阅"), systemImage: "xmark.circle") }
                } else {
                    Button { var d = SubDraft(s, mode: .change); d.status = .active; editing = d } label: { Label(LS("恢复订阅"), systemImage: "play.circle") }
                }
                Button { linking = true } label: { Label(LS("关联已有交易"), systemImage: "link") }
            }
            Section(LS("历史")) {
                ForEach(subscriptionTimeline(s)) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.kind == .event ? icon(item.eventKind) : item.kind == .gap ? "pause.circle" : "creditcard")
                            .foregroundStyle(item.kind == .gap ? Color.secondary : item.kind == .event ? Color.purple : Color.jade)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.subheadline).sensitive()
                            Text(item.to.map { item.from + " ~ " + $0 } ?? item.from).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).sensitive() }
                    }
                }
            }
            Section {
                if s.charges.isEmpty { Text(LS("还没有关联的扣费交易")).foregroundStyle(.secondary) }
                ForEach(s.charges.reversed()) { c in
                    NavigationLink(value: TxDest(c.txn)) { TxRow(t: c.txn, showDate: true) }
                        .swipeActions {
                            if c.txn.links.contains(s.link) {
                                Button(LS("取消关联")) {
                                    if let op = store.unlinkOp(c.txn, link: s.link) { Task { await store.commit([op], word: LS("已取消关联")) } }
                                }
                                .tint(.gray)
                            }
                        }
                }
            } header: {
                Text(LS("扣费记录（%@）", s.charges.count))
            } footer: {
                Text(LS("扣费交易带有链接 ^%@，在 Fava 中点链接即可查看全部扣费。", s.link))
            }
            Section {
                Button { editing = SubDraft(s, mode: .correct) } label: { Label(LS("修正记录"), systemImage: "pencil") }
                Button(LS("删除订阅"), role: .destructive) { confirmDelete = true }
            } footer: {
                Text(LS("「调价或更改」会新增一条带生效日期的记录，保留历史；「修正记录」直接修改最近一条，用于改正填错的内容。"))
            }
        }
        .listSectionSpacing(.compact)
        .confirmationDialog(LS("删除订阅「%@」？", name), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(LS("删除"), role: .destructive) { delete(s) }
        } message: {
            Text(LS("删除这个订阅的全部记录；扣费交易保留，链接也不会移除。不再续费时建议改为「取消订阅」。"))
        }
    }

    private func icon(_ k: SubEvent.Kind?) -> String {
        switch k {
        case .start?: return "flag"
        case .change?: return "arrow.up.arrow.down"
        case .pause?: return "pause.fill"
        case .resume?: return "play.fill"
        case .cancel?: return "xmark"
        default: return "circle"
        }
    }

    @ViewBuilder
    private func alertRow(_ a: SubAlert, _ s: Subscription) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(a.message, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(Color.warn).sensitive()
            HStack {
                switch a.kind {
                case .priceChanged:
                    if let v = a.amount {
                        Button(LS("更新为 %@", money(v, s.currency))) {
                            var d = SubDraft(s, mode: .change); d.amount = jsNumberString(v); d.date = a.date ?? Day.today(); editing = d
                        }
                    }
                case .fundingChanged:
                    if let acct = a.account {
                        Button(LS("改为 %@", acctLabel(acct))) { var d = SubDraft(s, mode: .change); d.funding = acct; editing = d }
                    }
                case .silent:
                    Button(LS("标记为暂停")) { stateChange = .paused }
                    Button(LS("标记为取消")) { stateChange = .cancelled }
                case .chargedWhileInactive:
                    Button(LS("恢复订阅")) { var d = SubDraft(s, mode: .change); d.status = .active; d.date = a.date ?? Day.today(); editing = d }
                case .trialEnding:
                    EmptyView()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func delete(_ s: Subscription) {
        let ops: [Op] = s.entries.enumerated().map { i, e in
            var op = Op(kind: .remove, path: e.file)
            op.old = e.src
            op.date = e.date
            if i == 0 { op.label = LS("删除订阅：%@", s.name) } else { op.silent = true }
            return op
        }
        Task { if await store.commit(ops, word: LS("已删除")) { dismiss() } }
    }
}

// MARK: - pause / cancel

struct SubStateSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let name: String
    let status: SubStatus
    @State private var date = Day.today()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(LS("生效日期"), selection: dateBinding($date), displayedComponents: .date)
                } footer: {
                    Text(status == .paused ? LS("暂停后不再提醒扣费；恢复时可以重新设定价格。") : LS("取消后不再提醒扣费，历史记录保留。"))
                }
                Section(LS("将写入")) { MonoText(text: subscriptionStateText(name, status, date: date)) }
            }
            .navigationTitle(status == .paused ? LS("暂停订阅") : LS("取消订阅"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(LS("保存")) { save() }.fontWeight(.semibold) }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let text = subscriptionStateText(name, status, date: date)
        guard let ops = store.makeOps(text, extra: OpExtra(label: (status == .paused ? LS("暂停订阅：%@") : LS("取消订阅：%@")).replacingOccurrences(of: "%@", with: name)), single: false) else { return }
        Task { await store.commit(ops, word: status == .paused ? LS("已暂停") : LS("已取消订阅"), closing: { dismiss() }) }
    }
}

// MARK: - link existing transactions

struct SubLinkSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var picked = Set<Int>()

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L, let s = store.subs.first(where: { $0.name == name }) {
                    let pool = candidates(L, s)
                    List {
                        if pool.isEmpty { Text(LS("没有找到同一科目或商户的未关联交易")).foregroundStyle(.secondary) }
                        ForEach(pool, id: \.id) { t in
                            Button { if picked.contains(t.id) { picked.remove(t.id) } else { picked.insert(t.id) } } label: {
                                HStack {
                                    Image(systemName: picked.contains(t.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.jade)
                                    TxRow(t: t, showDate: true)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(LS("关联 %@ 笔", picked.count)) { save(L, s, pool) }.fontWeight(.semibold).disabled(picked.isEmpty)
                        }
                    }
                } else { ProgressView() }
            }
            .navigationTitle(LS("关联已有交易"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } } }
        }
    }

    /// unlinked expenses to the same account or payee in the last two years, newest first
    private func candidates(_ L: Ledger, _ s: Subscription) -> [Entry] {
        let since = Day.shift(Day.today(), -760)
        let mine = Set(s.charges.map { $0.txn.id })
        return Array(L.txns.filter { t in
            t.date >= since && !t.synthetic && !mine.contains(t.id) && !t.links.contains(where: { $0.hasPrefix("sub-") })
                && t.postings.contains { $0.account.hasPrefix("Expenses:") }
                && (t.postings.contains { $0.account == s.account } || (!s.payee.isEmpty && t.payee == s.payee) || t.payee == s.name)
        }.reversed())
    }

    private func save(_ L: Ledger, _ s: Subscription, _ pool: [Entry]) {
        let txns = pool.filter { picked.contains($0.id) }
        Task {
            let ops = await store.linkOps(txns, link: s.link, label: LS("关联订阅：%@ %@ 笔", s.name, txns.count))
            guard !ops.isEmpty else { return }
            await store.commit(ops, word: LS("已关联 %@ 笔", txns.count), closing: { dismiss() })
        }
    }
}

// MARK: - edit

struct SubDraft: Identifiable {
    enum Mode { case new, change, correct }
    let id = UUID()
    var mode = Mode.new
    var name = ""
    var amount = ""
    var currency = "CNY"
    var period = SubPeriod.monthly
    var custom = false
    var start = Day.today()
    /// effective date of a change
    var date = Day.today()
    var account = ""
    var funding = ""
    var payee = ""
    var extended = false
    var next = Day.today()
    var trial = false
    var trialEnd = Day.shift(Day.today(), 30)
    var status = SubStatus.active
    var link = ""
    /// the subscription being changed
    var original: Subscription?
    /// transactions to link (from a candidate)
    var txns: [Entry] = []
    var picked = Set<Int>()

    init(currency: String) { self.currency = currency }

    init(_ s: Subscription, mode: Mode) {
        self.mode = mode
        name = s.name; amount = jsNumberString(s.amount); currency = s.currency; period = s.period
        custom = !SubPeriod.presets.contains(s.period)
        start = s.start; account = s.account; funding = s.funding; payee = s.payee
        extended = s.next != nil
        next = s.next ?? s.due(onOrAfter: Day.today())
        trial = s.trialEnd != nil
        trialEnd = s.trialEnd ?? Day.shift(Day.today(), 30)
        status = s.status; link = s.link; original = s
        date = Day.today()
    }

    init(_ c: SubCandidate) {
        name = c.payee; amount = jsNumberString(c.amount); currency = c.currency; period = c.period
        start = c.first; account = c.account; funding = c.funding; payee = c.payee
        txns = c.txns; picked = Set(c.txns.map { $0.id })
    }

    /// from a transaction: its expense leg, funding leg and date
    init(_ t: Entry, _ L: Ledger) {
        name = t.payee.isEmpty ? t.narration : t.payee
        payee = t.payee
        start = t.date
        if let e = t.postings.first(where: { $0.account.hasPrefix("Expenses:") }) {
            account = e.account
            amount = jsNumberString(abs(e.units ?? 0))
            currency = e.currency ?? L.base
        }
        funding = t.postings.first { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }?.account ?? ""
        txns = [t]; picked = [t.id]
    }

    var sub: Subscription? {
        guard let a = evalAmount(amount), a > 0, !name.trimmed.isEmpty else { return nil }
        var s = Subscription(name: name.trimmed, amount: a, currency: currency.trimmed.uppercased(), period: period, start: start,
                             account: account, funding: funding, payee: payee.trimmed,
                             next: extended && next > (mode == .change ? date : start) ? next : nil, status: status,
                             link: link.isEmpty ? nil : link, trialEnd: trial ? trialEnd : nil)
        if mode == .change { s.status = .active }
        return s
    }

    /// the text to write: a whole first line, or only what changed for a dated change
    var text: String? {
        guard let s = sub else { return nil }
        switch mode {
        case .new: return subscriptionText(s, date: start)
        case .correct: return subscriptionText(s, date: original?.entry?.date ?? start)
        case .change:
            var lines = [subscriptionText(s, date: date, full: false)]
            let q = quoted
            if let o = original {
                if s.account != o.account { lines.insert("  account: " + q(s.account), at: 1) }
                if s.funding != o.funding { lines.insert("  funding: " + q(s.funding), at: 1) }
                if s.payee != o.payee { lines.insert("  payee: " + q(s.payee), at: 1) }
                if s.trialEnd != o.trialEnd, let t = s.trialEnd { lines.insert("  trial_end: " + t, at: 1) }
            }
            return lines.joined(separator: "\n")
        }
    }
}

struct SubEditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var draft: SubDraft
    @State private var picking: PickTarget?

    enum PickTarget: String, Identifiable { case account, funding; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            Form {
                if draft.mode == .change {
                    Section {
                        DatePicker(LS("生效日期"), selection: dateBinding($draft.date), displayedComponents: .date)
                    } footer: {
                        Text(draft.original?.status != .active && draft.status == .active
                             ? LS("从这一天起恢复订阅，扣费周期从这一天重新计算。") : LS("新增一条带日期的记录，之前的价格和历史保留。"))
                    }
                }
                Section {
                    LabeledContent(LS("名称")) {
                        TextField(LS("如 iCloud+、Netflix"), text: $draft.name).multilineTextAlignment(.trailing)
                            .disabled(draft.mode == .change)
                    }
                    LabeledContent(LS("金额")) {
                        HStack(spacing: 6) {
                            TextField("0.00", text: $draft.amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing).font(.body.monospacedDigit())
                            TextField("CNY", text: $draft.currency).frame(width: 52).multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled().foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent(LS("商户")) {
                        TextField(LS("可选"), text: $draft.payee).multilineTextAlignment(.trailing)
                    }
                } footer: {
                    if nameTaken { Text(LS("已有同名订阅，请换一个名称")).foregroundStyle(Color.warn) }
                }
                Section {
                    Picker(LS("周期"), selection: Binding(get: { draft.custom ? nil : draft.period }, set: { v in
                        if let v = v { draft.period = v; draft.custom = false } else { draft.custom = true }
                    })) {
                        ForEach(SubPeriod.presets, id: \.self) { Text($0.name).tag(Optional($0)) }
                        Text(LS("自定义")).tag(SubPeriod?.none)
                    }
                    if draft.custom {
                        Stepper(LS("每 %@", draft.period.n), value: $draft.period.n, in: 1...365)
                        Picker(LS("单位"), selection: $draft.period.unit) {
                            Text(LS("天")).tag(PeriodUnit.day)
                            Text(LS("周")).tag(PeriodUnit.week)
                            Text(LS("月")).tag(PeriodUnit.month)
                            Text(LS("年")).tag(PeriodUnit.year)
                        }
                        .pickerStyle(.segmented)
                    }
                    if draft.mode != .change {
                        DatePicker(LS("首次扣费"), selection: dateBinding($draft.start), displayedComponents: .date)
                    }
                    Toggle(LS("免费试用"), isOn: $draft.trial.animation())
                    if draft.trial {
                        DatePicker(LS("试用结束"), selection: dateBinding($draft.trialEnd), displayedComponents: .date)
                    }
                    Toggle(LS("赠送 / 延长周期"), isOn: $draft.extended.animation())
                        .onChange(of: draft.extended) { _, on in
                            let from = draft.mode == .change ? draft.date : draft.start
                            if on, draft.next <= from { draft.next = draft.period.add(from, 1) }
                        }
                    if draft.extended {
                        DatePicker(LS("下次扣费日"), selection: dateBinding($draft.next), displayedComponents: .date)
                    }
                } header: {
                    Text(LS("扣费周期"))
                } footer: {
                    if draft.extended {
                        Text(LS("赠送或延长的时间到「下次扣费日」为止，之后按原周期（%@）继续计算。", draft.period.name))
                    } else if draft.trial {
                        Text(LS("试用结束前会提醒你，试用期内不提示待记账。"))
                    }
                }
                Section {
                    Button { picking = .account } label: {
                        LabeledContent(LS("支出科目"), value: draft.account.isEmpty ? LS("选择") : acctDisplay(draft.account))
                    }
                    .foregroundStyle(.primary)
                    Button { picking = .funding } label: {
                        LabeledContent(LS("付款账户"), value: draft.funding.isEmpty ? LS("选择") : acctDisplay(draft.funding))
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text(LS("新记的交易科目、商户一致且金额相近时，会自动关联到这个订阅。"))
                }
                if !draft.txns.isEmpty {
                    Section {
                        ForEach(draft.txns.reversed(), id: \.id) { t in
                            Button {
                                if draft.picked.contains(t.id) { draft.picked.remove(t.id) } else { draft.picked.insert(t.id) }
                            } label: {
                                HStack {
                                    Image(systemName: draft.picked.contains(t.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.jade)
                                    TxRow(t: t, showDate: true)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(LS("关联这些交易（%@/%@）", draft.picked.count, draft.txns.count))
                    }
                }
                if let t = draft.text {
                    Section(LS("将写入")) { MonoText(text: t) }
                }
            }
            .keyboardDone()
            .navigationTitle(draft.mode == .new ? LS("添加订阅") : draft.mode == .correct ? LS("修正记录")
                             : draft.original?.status != .active ? LS("恢复订阅") : LS("调价或更改"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LS("保存")) { save() }.fontWeight(.semibold).disabled(draft.sub == nil || nameTaken)
                }
            }
            .sheet(item: $picking) { p in
                AccountPicker(title: p == .account ? LS("支出科目") : LS("付款账户"),
                              prefixes: p == .account ? ["Expenses:"] : ["Liabilities:", "Assets:"],
                              current: p == .account ? draft.account : draft.funding) { a in
                    if p == .account { draft.account = a } else { draft.funding = a }
                }
            }
        }
    }

    /// another subscription already uses this name
    private var nameTaken: Bool {
        let n = draft.name.trimmed
        return n != draft.original?.name && store.subs.contains { $0.name == n }
    }

    private func save() {
        guard let s = draft.sub, let text = draft.text, !nameTaken else { return }
        let label = LS("订阅：%@ %@", s.name, money(s.amount, s.currency))
        Task {
            var ops: [Op] = []
            switch draft.mode {
            case .new:
                guard let x = store.makeOps(text, extra: OpExtra(label: label), single: false) else { return }
                ops = x
                let link = s.link
                ops += await store.linkOps(draft.txns.filter { draft.picked.contains($0.id) }, link: link, label: nil)
            case .correct:
                guard let o = draft.original, let e = o.entry else { return }
                var op = Op(kind: .replace, path: e.file)
                op.old = e.src; op.text = text; op.date = e.date; op.label = label
                ops = [op]
                // a new name: rename the other lines too
                if s.name != o.name {
                    for other in o.entries where other !== e {
                        var r = Op(kind: .replace, path: other.file)
                        r.old = other.src
                        r.text = other.src.replacingOccurrences(of: "\"subscription\" " + quoted(o.name), with: "\"subscription\" " + quoted(s.name))
                        r.date = other.date
                        r.silent = true
                        ops.append(r)
                    }
                }
            case .change:
                // a second change on the same day replaces that day's line
                if let o = draft.original, let e = o.entry, e.date == draft.date, o.entries.count > 1 {
                    var op = Op(kind: .replace, path: e.file)
                    op.old = e.src; op.text = text; op.date = e.date; op.label = label
                    ops = [op]
                } else {
                    guard let x = store.makeOps(text, extra: OpExtra(label: label), single: false) else { return }
                    ops = x
                }
            }
            await store.commit(ops, word: draft.mode == .new ? LS("已添加订阅") : LS("已更新订阅"), closing: { dismiss() })
        }
    }
}
