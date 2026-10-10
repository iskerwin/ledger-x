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
        guard !s.account.isEmpty, !s.paymentAccount.isEmpty else {
            show(LS("请先为「%@」设置支出科目和付款账户", s.name))
            return
        }
        let q = quoted
        let payee = s.payee.isEmpty ? s.name : s.payee
        let narration = s.payee.isEmpty || s.payee == s.name ? "" : s.name
        let text = """
        \(date) * \(q(payee)) \(q(narration)) ^\(s.link)
          \(s.account)  \(toFixed(s.amount, 2)) \(s.currency)
          \(s.paymentAccount)
        """
        guard let ops = makeOps(alignText(text), extra: OpExtra(label: LS("订阅扣费：%@ %@", s.name, money(s.amount, s.currency))), single: true) else { return }
        await commit(ops, word: LS("已记录 %@", s.name))
    }

    /// links that belong to an existing subscription (any other ^sub-… is left over from a deleted one)
    var ownedSubLinks: Set<String> { Set(subs.map { $0.link }) }

    /// add `^link` to the header of each transaction; a left-over or other subscription's link is replaced
    func linkOps(_ txns: [Entry], link: String, label: String?) async -> [Op] {
        var ops: [Op] = []
        var files: [String: [String]] = [:]
        for e in txns where !e.links.contains(link) {
            if let oldLink = e.links.first(where: { $0.hasPrefix("sub-") }) {
                var lines = e.src.components(separatedBy: "\n")
                lines[0] = lines[0].components(separatedBy: " ").map { $0 == "^" + oldLink ? "^" + link : $0 }.joined(separator: " ")
                var op = Op(kind: .replace, path: e.file)
                op.old = e.src; op.text = lines.joined(separator: "\n"); op.date = e.date
                if ops.isEmpty, let l = label { op.label = l } else { op.silent = true }
                ops.append(op)
                continue
            }
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

    /// remove the subscription's link from all its charges
    func unlinkAllOps(_ s: Subscription) -> [Op] {
        var ops: [Op] = []
        for c in s.charges where c.txn.links.contains(s.link) {
            guard var op = unlinkOp(c.txn, link: s.link) else { continue }
            op.label = nil; op.silent = true
            ops.append(op)
        }
        return ops
    }

    /// subscription lines that are not in the subscriptions file yet: move them there (one commit)
    var misplacedSubLines: [Entry] { subs.flatMap { $0.entries }.filter { $0.file != layout.subscriptionsPath } }

    func moveSubLinesOps() -> [Op]? {
        let lines = misplacedSubLines
        guard !lines.isEmpty else { return [] }
        var ops: [Op] = lines.enumerated().map { i, e in
            var op = Op(kind: .remove, path: e.file)
            op.old = e.src; op.date = e.date
            if i == 0 { op.label = LS("整理订阅记录到 %@", layout.subscriptionsPath) } else { op.silent = true }
            return op
        }
        guard let ins = makeOps(lines.sorted { $0.date < $1.date }.map { trimTrailingSpaces($0.src) }.joined(separator: "\n\n"),
                                extra: OpExtra(silent: true), single: false) else { return nil }
        ops += ins
        return ops
    }

    /// new transactions that match a subscription get its link (returns the names linked)
    func autoLinkSubscriptions(_ ops: [Op]) -> ([Op], [String]) {
        guard let L = L, !subs.isEmpty else { return (ops, []) }
        let owned = ownedSubLinks
        var names: [String] = []
        let out = ops.map { op -> Op in
            guard op.kind == .insert, let text = op.text else { return op }
            let blocks = text.components(separatedBy: "\n\n").map { block -> String in
                let r = checkText(block, L)
                guard r.entries.count == 1, let t = r.entries.first, t.type == .txn, !t.links.contains(where: { owned.contains($0) }),
                      t.meta["subscription"] == nil,
                      let exp = t.postings.first(where: { $0.account.hasPrefix("Expenses:") }), let u = exp.units, u > 0, let c = exp.currency
                else { return block }
                let payee = t.payee.isEmpty ? t.narration : t.payee
                // two subscriptions fit equally (same payee, account and price): leave it to you
                guard ambiguousSubscriptions(payee: payee, account: exp.account, amount: u, currency: c, subs).count <= 1,
                      let s = matchSubscription(payee: payee, account: exp.account, amount: u, currency: c, subs)
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
        let upcoming = subs.map { ($0, $0.nextCharge(onOrAfter: today)) }.min { $0.1 < $1.1 }
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
                Text(due.sub.manual ? LS("%@ 应续费 · 未记录", due.date) : LS("%@ 应扣费 · 未入账", due.date)).font(.caption).foregroundStyle(Color.warn)
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
        let active = all.filter { $0.status == .active }.sorted { $0.nextCharge(onOrAfter: today) < $1.nextCharge(onOrAfter: today) }
        let misplaced = store.misplacedSubLines.count
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
                NavigationLink { SubscriptionCalendarView() } label: { Label(LS("订阅日历"), systemImage: "calendar") }
            }
            if misplaced > 0 {
                Section {
                    Button { tidy() } label: {
                        Label(LS("把 %@ 条订阅记录移到 %@", misplaced, store.layout.subscriptionsPath), systemImage: "tray.and.arrow.down")
                    }
                } footer: {
                    Text(LS("订阅记录集中放在单独的文件里，主文件只保留 include；移动在一次提交中完成。文件名可在 设置 → 仓库结构 中修改。"))
                }
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

    private func tidy() {
        guard let ops = store.moveSubLinesOps(), !ops.isEmpty else { return }
        Task { await store.commit(ops, word: LS("已整理订阅记录")) }
    }

    private func row(_ s: Subscription, _ L: Ledger, _ today: String) -> some View {
        let next = s.nextCharge(onOrAfter: today)
        let alerts = subscriptionAlerts(s, today: today)
        let when: String
        if s.status == .active {
            when = s.period.name + " · " + LS("下次 %@（%@）", next, daysText(next, today: today))
        } else {
            var tail = s.statusDate
            if let u = s.until, u >= today { tail = LS("可用至 %@", u) }
            when = s.period.name + " · " + s.status.name + " · " + tail
        }
        let count = s.charges.filter { !$0.refund }.count
        let countLine = LS("已扣 %@ 期 · 累计 %@", count, money(s.totalPaid, s.currency, 0))
        let icon = s.status == .active ? "repeat" : s.status == .paused ? "pause" : "xmark"
        let tint: Color = s.status == .active ? .purple : .gray
        return NavigationLink { SubscriptionDetailView(name: s.name) } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: icon, color: tint, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(s.name)
                        if !alerts.isEmpty { Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(Color.warn) }
                    }
                    Text(when).font(.caption).foregroundStyle(.secondary)
                    Text(countLine).font(.caption2).foregroundStyle(.secondary).sensitive()
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
    @State private var undoing: SubTimelineItem?
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
        let next = s.nextCharge(onOrAfter: today)
        let alerts = subscriptionAlerts(s, today: today)
        let statusText = s.status.name + " · " + s.statusDate + (s.until.map { $0 >= today ? " · " + LS("可用至 %@", $0) : "" } ?? "")
        return List {
            Section {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(money(s.amount, s.currency) + " / " + s.period.name).font(.title3.weight(.semibold)).sensitive()
                                Text(s.status == .active ? LS(s.manual ? "下次续费 %@（%@）" : "下次扣费 %@（%@）", next, daysText(next, today: today)) : statusText)
                                    .font(.subheadline).foregroundStyle(s.status == .active ? Color.secondary : Color.warn)
                            }
                            Spacer()
                        }
                        HStack(alignment: .top) {
                            Figure(label: LS("累计已付"), value: money(s.totalPaid, s.currency, 0))
                            Spacer()
                            Figure(label: LS("今年"), value: money(s.paid(in: String(today.prefix(4))), s.currency, 0))
                            Spacer()
                            Figure(label: LS("扣费次数"), value: "\(s.charges.filter { !$0.refund }.count)", alignment: .trailing)
                        }
                        Text([s.manual ? LS("手动续费") : LS("自动扣费"), s.variable ? LS("金额不固定") : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if !s.paymentAccount.isEmpty {
                            Text(LS("付款账户：%@", acctDisplay(s.paymentAccount)) + (s.lastCharge.map { _ in LS("（按最近一次扣费）") } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
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
                    Button { Task { await store.recordSubscription(s, date: s.due(onOrBefore: today) ?? today) } } label: { Label(s.manual ? LS("记一笔续费") : LS("记一笔扣费"), systemImage: "plus.circle") }
                    Button { editing = SubDraft(s, mode: .change) } label: { Label(LS("调价或更改"), systemImage: "slider.horizontal.3") }
                    Button { skip(s, next) } label: { Label(LS("跳过下一期（%@）", next), systemImage: "forward.end") }
                    Button { stateChange = .paused } label: { Label(LS("暂停"), systemImage: "pause.circle") }
                    Button(role: .destructive) { stateChange = .cancelled } label: { Label(LS("取消订阅"), systemImage: "xmark.circle") }
                } else {
                    Button { var d = SubDraft(s, mode: .change); d.status = .active; editing = d } label: { Label(LS("恢复订阅"), systemImage: "play.circle") }
                }
                Button { linking = true } label: { Label(LS("关联已有交易"), systemImage: "link") }
            }
            Section {
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
                    .swipeActions {
                        // a change, pause, resume, cancel or skip can be taken back (not the very first line)
                        if item.kind == .event, item.eventKind != .start, item.entry != nil {
                            Button(LS("撤销")) { undoing = item }.tint(.orange)
                        }
                    }
                }
            } header: {
                Text(LS("历史"))
            } footer: {
                Text(LS("左滑变更记录可撤销。"))
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
            let n = s.charges.filter { $0.txn.links.contains(s.link) }.count
            Button(n > 0 ? LS("删除，并移除 %@ 笔交易的链接", n) : LS("删除"), role: .destructive) { delete(s, unlink: true) }
            if n > 0 { Button(LS("删除，保留交易上的链接")) { delete(s, unlink: false) } }
        } message: {
            Text(LS("删除这个订阅的全部记录，扣费交易本身保留。不再续费时建议改为「取消订阅」。"))
        }
        .confirmationDialog(LS("撤销这条记录？"), isPresented: Binding(get: { undoing != nil }, set: { if !$0 { undoing = nil } }), titleVisibility: .visible) {
            Button(LS("撤销"), role: .destructive) { if let u = undoing { undo(u, s) } }
        } message: {
            Text(undoing.map { $0.from + " " + $0.title } ?? "")
        }
    }

    private func icon(_ k: SubEvent.Kind?) -> String {
        switch k {
        case .start?: return "flag"
        case .change?: return "arrow.up.arrow.down"
        case .pause?: return "pause.fill"
        case .resume?: return "play.fill"
        case .cancel?: return "xmark"
        case .skip?: return "forward.end"
        default: return "arrow.uturn.backward"
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
                case .silent:
                    Button(LS("补记一笔续费")) { Task { await store.recordSubscription(s, date: s.due(onOrBefore: Day.today()) ?? Day.today()) } }
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

    private func delete(_ s: Subscription, unlink: Bool) {
        var ops: [Op] = s.entries.enumerated().map { i, e in
            var op = Op(kind: .remove, path: e.file)
            op.old = e.src
            op.date = e.date
            if i == 0 { op.label = LS("删除订阅：%@", s.name) } else { op.silent = true }
            return op
        }
        if unlink { ops += store.unlinkAllOps(s) }
        Task { if await store.commit(ops, word: LS("已删除")) { dismiss() } }
    }

    private func undo(_ item: SubTimelineItem, _ s: Subscription) {
        guard let e = item.entry else { return }
        var op = Op(kind: .remove, path: e.file)
        op.old = e.src
        op.date = e.date
        op.label = LS("撤销订阅记录：%@ %@ %@", s.name, item.from, item.title)
        undoing = nil
        Task { await store.commit([op], word: LS("已撤销")) }
    }

    private func skip(_ s: Subscription, _ due: String) {
        let text = subscriptionSkipText(s.name, due: due)
        guard let ops = store.makeOps(text, extra: OpExtra(label: LS("跳过一期：%@ %@", s.name, due)), single: false) else { return }
        Task { await store.commit(ops, word: LS("已跳过 %@ 这一期", due)) }
    }
}

// MARK: - pause / cancel

struct SubStateSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let name: String
    let status: SubStatus
    @State private var date = Day.today()
    @State private var keepUntil = true
    @State private var until = Day.today()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(LS("生效日期"), selection: dateBinding($date), displayedComponents: .date)
                } footer: {
                    Text(status == .paused ? LS("暂停后不再提醒扣费；恢复时可以重新设定价格。") : LS("取消后不再提醒扣费，历史记录保留。"))
                }
                if status == .cancelled {
                    Section {
                        Toggle(LS("本期仍可使用"), isOn: $keepUntil)
                        if keepUntil { DatePicker(LS("可用至"), selection: dateBinding($until), displayedComponents: .date) }
                    } footer: {
                        Text(LS("取消后多数订阅仍能用到已付期末。"))
                    }
                }
                Section(LS("将写入")) { MonoText(text: text) }
            }
            .navigationTitle(status == .paused ? LS("暂停订阅") : LS("取消订阅"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(LS("保存")) { save() }.fontWeight(.semibold) }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let s = store.subs.first(where: { $0.name == name }), let c = s.lastCharge {
                until = max(Day.shift(s.period.add(c.date, 1), -1), date)
            }
        }
    }

    private var text: String {
        subscriptionStateText(name, status, date: date, until: status == .cancelled && keepUntil ? until : nil)
    }

    private func save() {
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
                    TxPicker(hint: SubHint(s), exclude: Set(s.charges.map { $0.txn.id }), picked: $picked)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(LS("关联 %@ 笔", picked.count)) { save(L, s) }.fontWeight(.semibold).disabled(picked.isEmpty)
                            }
                        }
                } else { ProgressView() }
            }
            .navigationTitle(LS("关联已有交易"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } } }
        }
    }

    private func save(_ L: Ledger, _ s: Subscription) {
        let txns = picked.sorted().compactMap { $0 < L.txns.count ? L.txns[$0] : nil }
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
    var manual = false
    var variable = false
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
        manual = s.manual; variable = s.variable
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
        s.manual = manual
        s.variable = variable
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
                if s.manual != o.manual { lines.insert("  renew: " + q(s.manual ? "manual" : "auto"), at: 1) }
                if s.variable != o.variable { lines.insert("  variable: " + (s.variable ? "TRUE" : "FALSE"), at: 1) }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// what this change does, for the commit message and the toast
    var changeSummary: String {
        guard let s = sub else { return "" }
        guard let o = original else { return LS("新订阅：%@ %@ / %@", s.name, money(s.amount, s.currency), s.period.name) }
        var parts: [String] = []
        if o.status != .active && mode == .change { parts.append(LS("恢复")) }
        if abs(s.amount - o.amount) > 0.005 { parts.append(LS("调价 %@ → %@", money(o.amount, o.currency), money(s.amount, s.currency))) }
        if s.period != o.period { parts.append(o.period.name + " → " + s.period.name) }
        if s.account != o.account { parts.append(LS("科目 → %@", acctLabel(s.account))) }
        if s.funding != o.funding { parts.append(LS("付款账户 → %@", acctLabel(s.funding))) }
        if s.manual != o.manual { parts.append(s.manual ? LS("改为手动续费") : LS("改为自动扣费")) }
        if s.variable != o.variable { parts.append(s.variable ? LS("金额不固定") : LS("金额固定")) }
        if s.name != o.name { parts.append(LS("改名为 %@", s.name)) }
        if s.trialEnd != o.trialEnd { parts.append(LS("试用期")) }
        if s.next != o.next { parts.append(LS("下次扣费日")) }
        let what = parts.isEmpty ? LS("更新") : parts.joined(separator: LS("，"))
        return mode == .change ? LS("%@：%@（%@ 起）", s.name, what, date) : LS("%@：%@", s.name, what)
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
                    Picker(LS("续费方式"), selection: $draft.manual) {
                        Text(LS("自动扣费")).tag(false)
                        Text(LS("手动续费")).tag(true)
                    }
                    Toggle(LS("金额不固定（按量计费）"), isOn: $draft.variable)
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
                    } else if draft.manual {
                        Text(LS("手动续费：到期前提醒你去续费；自动扣费：提醒将要扣费，漏记时提示补记。"))
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
                    Text(LS("新记的交易科目、商户一致且金额相近时，会自动关联到这个订阅。付款账户只是默认值，每次扣费用哪个账户以交易为准，「记一笔」时沿用最近一次扣费的账户。"))
                }
                if draft.mode == .new {
                    Section {
                        NavigationLink {
                            TxPicker(hint: SubHint(payee: draft.payee.isEmpty ? draft.name : draft.payee, name: draft.name,
                                                   account: draft.account, amount: evalAmount(draft.amount) ?? 0),
                                     exclude: [], picked: $draft.picked)
                                .navigationTitle(LS("选择要关联的交易"))
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            LabeledContent(LS("关联交易"), value: draft.picked.isEmpty ? LS("选择") : LS("%@ 笔", draft.picked.count))
                        }
                    } footer: {
                        Text(LS("把过去的扣费交易关联到这个订阅，可搜索商户、说明、金额或日期。"))
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
        // a new subscription gets a link no other subscription uses ("sub-icloud-2")
        if draft.mode == .new && draft.link.isEmpty {
            draft.link = uniqueSubscriptionLink(draft.name.trimmed, taken: store.ownedSubLinks)
        }
        guard let s = draft.sub, let text = draft.text, !nameTaken else { return }
        let label = draft.changeSummary
        Task {
            var ops: [Op] = []
            switch draft.mode {
            case .new:
                guard let x = store.makeOps(text, extra: OpExtra(label: label), single: false) else { return }
                ops = x
                let link = s.link
                let txns = draft.picked.sorted().compactMap { id in store.L.flatMap { id < $0.txns.count ? $0.txns[id] : nil } }
                ops += await store.linkOps(txns, link: link, label: nil)
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
            await store.commit(ops, word: draft.mode == .new ? LS("已添加订阅") : label, closing: { dismiss() })
        }
    }
}
