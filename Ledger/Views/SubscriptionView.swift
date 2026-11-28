import SwiftUI
import LedgerKit

struct SubscriptionsDest: Hashable {}
struct SubDetailDest: Hashable { let name: String }
struct SubCalendarDest: Hashable {}

extension View {
    /// subscription pages pushed by value, so they live in the tab's navigation path like everything else
    /// (a view-based link mixed with value-based ones makes SwiftUI push pages twice)
    /// pages every tab can open: subscriptions, links, reimbursements, editing an account (from its register)
    func subscriptionDestinations() -> some View {
        navigationDestination(for: SubDetailDest.self) { SubscriptionDetailView(name: $0.name) }
            .navigationDestination(for: SubCalendarDest.self) { _ in SubscriptionCalendarView().privacyToolbar() }
            .navigationDestination(for: LinkDest.self) { LinkDetailView(link: $0.link).privacyToolbar() }
            .navigationDestination(for: ReimbursementsDest.self) { _ in ReimbursementsView().privacyToolbar() }
            .navigationDestination(for: ReimbBatchDest.self) { ReimbBatchView(link: $0.link).privacyToolbar() }
            .navigationDestination(for: UnclaimedDest.self) { _ in UnclaimedView().privacyToolbar() }
            .navigationDestination(for: AccountEditDest.self) { AccountEditView(name: $0.name) }
    }
}

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
    /// a subscription's icon: its own account's where that has one of its own (Cloud, Phone…), so subscriptions
    /// in one category tell apart; otherwise the category's, as the user set it
    func subIcon(_ s: Subscription) -> String {
        if let own = ownCategoryIcon(s.account), Symbols.valid(own) { return own }
        return catIcon(catOf(s.account))
    }

    /// a subscription's card: drawn for the service it is for, else in its category's picked colour or one of its own
    func subFace(_ s: Subscription) -> (subject: FaceSubject, tint: Color) {
        let tint = pickedTint(s.account) ?? CategoryPalette.color(stableColorSlot(s.name, count: CategoryPalette.colors.count))
        return (.subscription(link: s.link, name: s.name, payee: s.payee, symbol: subIcon(s)), tint)
    }

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
        let ignored = Set(ignoredSubIDs)
        if let c = Store.candCache, c.0 == version { return c.1.filter { !ignored.contains($0.id) } }
        let s = subscriptionCandidates(L, subs: subs)
        Store.candCache = (version, s)
        return s.filter { !ignored.contains($0.id) }
    }
    static var candCache: (Int, [SubCandidate])?

    func ignoreCandidate(_ c: SubCandidate) {
        Task { await ignoreSubSuggestion(c.id, label: LS("不再提示订阅：%@", c.payee)) }
    }

    /// 记一笔 for a subscription: the 记一笔 card filled in from it (payee, category, paying account, amount, its
    /// ^sub- link), dated today like any new entry; the date and amount can be changed before saving
    func recordSubscription(_ s: Subscription) {
        guard !s.account.isEmpty, !s.paymentAccount.isEmpty else {
            showFailure(LS("请先为「%@」设置支出科目和付款账户", s.name))
            return
        }
        var d = newDraftFor(.expense)
        d.date = Day.today()
        d.payee = s.payee.isEmpty ? s.name : s.payee
        d.narration = s.payee.isEmpty || s.payee == s.name ? "" : s.name
        d.account = s.account
        d.funding = s.paymentAccount
        d.amount = jsNumberString(roundTo(s.amount, 2))
        d.currency = s.currency
        d.link = s.link
        draft = d
        openAdd(full: false)
        show(LS("已按订阅「%@」填好，核对日期和金额后保存", s.name))
    }

    /// links that belong to an existing subscription (any other ^sub-… is left over from a deleted one)
    var ownedSubLinks: Set<String> { Set(subs.map { $0.link }) }

    /// add `^link` to the header of each transaction; a left-over or other subscription's link is replaced
    func linkOps(_ txns: [Entry], link: String, label: String?) async -> [Op]? {
        let ledgerID = cfg.id
        var files: [String: String] = [:]
        for file in Set(txns.filter { !$0.links.contains(link) }.map(\.file)) { files[file] = try? await fileText(file) }
        guard cfg.id == ledgerID, let ops = subscriptionLinkOps(txns, link: link, label: label, files: files) else {
            showFailure(LS("记录或账本已变化，请重新打开后再试")); return nil
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
        guard let L else { return (ops, []) }
        return LedgerKit.autoLinkSubscriptions(ops, L, subs: subs)
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
        // Queue behind the save confirmation. A fixed delay used to replace that confirmation early.
        show(LS("「%@」看起来是%@扣费", c.payee, c.period.name), action: LS("加入订阅")) { @MainActor [weak self] in self?.subSuggestion = c }
    }
}

// MARK: - overview section

struct SubscriptionOverviewSection: View {
    @Environment(Store.self) var store
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
                HStack(spacing: AppSpacing.icon) {
                    IconBadge(symbol: "repeat", size: 28)
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
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
    @Environment(Store.self) var store
    let due: SubDue
    @State private var busy = false

    var body: some View {
        HStack(spacing: AppSpacing.control) {
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                Text(due.sub.name)
                Text(due.sub.manual ? LS("%@ 应续费 · 未记录", due.date) : LS("%@ 应扣费 · 未入账", due.date)).font(.caption).foregroundStyle(Color.warn)
            }
            Spacer()
            Text(money(due.sub.amount, due.sub.currency)).monospacedDigit().sensitive()
            Button {
                busy = true
                store.recordSubscription(due.sub); busy = false
            } label: {
                Label(LS("记一笔"), systemImage: "plus.circle").labelStyle(ControlLabelStyle()).font(.subheadline.weight(.semibold))
            }
            .rowButton(filled: true)
            .disabled(busy)
        }
    }
}

// MARK: - list

struct SubscriptionsView: View {
    @Environment(Store.self) var store
    @State private var editing: SubDraft?
    @State private var demoDetail: String?
    @State private var opening = CardOpening()
    @Namespace private var cardSpace

    var body: some View {
        Group {
            if let L = store.L { page(L) } else { PageLoading() }
        }
        .navigationTitle(LS("订阅管理"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if opening.key == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: SubCalendarDest()) { Image(systemName: "calendar") }
                        .accessibilityLabel(LS("订阅日历"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = SubDraft(currency: store.L?.base ?? "CNY") } label: { Image(systemName: "plus") }
                        .accessibilityLabel(LS("添加订阅"))
                }
            }
        }
        .cardStacks(opening, in: cardSpace)
        .sheet(item: $editing) { SubEditSheet(draft: $0) }
        .navigationDestination(item: $demoDetail) { SubscriptionDetailView(name: $0) }
        .task {
            if let n = store.demoEnv["LEDGER_SUB_DETAIL"] { demoDetail = n; return }
            if store.demoEnv["LEDGER_SUB_EDIT"] != nil, let c = store.subCandidates.first { editing = SubDraft(c) }
            else if store.demoEnv["LEDGER_SUB_EDIT"] != nil, let s = store.subs.first { editing = SubDraft(s, mode: .change) }
        }
    }

    /// the stacks, and over them the open card's subscription (`CardOpening`): its page under the stacks, so the cards
    /// coming back pass over it, and its card over them
    private func page(_ L: Ledger) -> some View {
        let today = Day.today()
        let all = store.subs
        let cards = SubCards(all, today: today)
        let open = opening.key.flatMap { link in all.first { $0.link == link } }
        return ZStack(alignment: .top) {
            if let open {
                VStack(spacing: 0) {
                    // its card's place: the card itself is drawn on top, where it moves to
                    openCard(open, today: today).hidden().accessibilityHidden(true)
                    SubscriptionDetailView(name: open.name, close: { opening.close() })
                }
                .transition(.opacity)
            }
            stacks(L, active: cards.active, inactive: cards.inactive, today: today)
                .allowsHitTesting(opening.key == nil)
                .accessibilityHidden(opening.key != nil)
            if let open {
                Button { opening.close() } label: { SubCard(s: open, today: today) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sub.card." + open.name)
                    .modifier(CardMatch(key: open.link))
                    .modifier(OpenCardPlace())
            }
        }
        // deleted, or gone with a refresh: back to the stacks at once
        .onChange(of: open == nil) { _, gone in if gone && opening.key != nil { opening.reset() } }
    }

    private func openCard(_ s: Subscription, today: String) -> some View {
        SubCard(s: s, today: today, still: true).modifier(OpenCardPlace())
    }

    /// the page under the cards: drawn outside a List, so the cards are whole (a List cuts the corners of a row at a
    /// section's edge rounder than a card's) and one moves to the top with `matchedGeometryEffect`
    private func stacks(_ L: Ledger, active: [Subscription], inactive: [Subscription], today: String) -> some View {
        let all = store.subs
        let misplaced = store.misplacedSubLines.count
        let due = subscriptionsDue(L, today: today, subs: all)
        let monthly = active.reduce(0.0) { $0 + (toCNY(L, $1.monthly, $1.currency) ?? 0) }
        let year = String(today.prefix(4))
        let paidThisYear = all.reduce(0.0) { $0 + (toCNY(L, $1.paid(in: year), $1.currency) ?? 0) }
        let cands = store.subCandidates
        // while one is open the rest of the page goes, the cards go down below the screen
        let rest = opening.key == nil ? 1.0 : 0
        return ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.summary) {
                Card(padding: AppSpacing.summary) {
                    VStack(alignment: .leading, spacing: AppSpacing.content) {
                        VStack(alignment: .leading, spacing: AppSpacing.detail) {
                            Text(LS("月均")).font(.subheadline).foregroundStyle(.secondary)
                            Text(money(monthly, L.base)).heroAmount(HeroAmount.summary).monospacedDigit()
                                .rollingNumber(monthly).sensitive()
                        }
                        Divider()
                        FigureRow(items: [
                            .init(label: LS("%@ 年已付", year), value: money(paidThisYear, L.base, 0)),
                            .init(label: LS("订阅中"), value: "\(active.count)"),
                        ], alignment: .center)
                    }
                }
                .opacity(rest)
                if misplaced > 0 {
                    GroupedSection {
                        GroupedRow {
                            Button { tidy() } label: {
                                Label(LS("把 %@ 条订阅记录移到 %@", misplaced, store.layout.subscriptionsPath), systemImage: "tray.and.arrow.down").labelStyle(ControlLabelStyle())
                            }
                        }
                    } header: {
                        EmptyView()
                    } footer: {
                        Text(LS("订阅记录集中放在单独的文件里，主文件只保留 include；移动在一次提交中完成。文件名可在 设置 → 仓库结构 中修改。"))
                    }
                    .opacity(rest)
                }
                if !due.isEmpty {
                    GroupedSection {
                        ForEach(Array(due.enumerated()), id: \.element.id) { i, d in
                            if i > 0 { GroupedDivider() }
                            GroupedRow { SubDueRow(due: d) }
                        }
                    } header: {
                        Text(LS("待记账"))
                    }
                    .opacity(rest)
                }
                if !cands.isEmpty {
                    GroupedSection {
                        ForEach(Array(cands.enumerated()), id: \.element.id) { i, c in
                            if i > 0 { GroupedDivider() }
                            candidateRow(c)
                        }
                    } header: {
                        Text(LS("发现可能的订阅"))
                    } footer: {
                        HintFooter(LS("同一收付款方按固定周期扣费的交易。加入后会把这些交易关联到订阅。"), tip: LS("长按可忽略。"), .hold)
                    }
                    .opacity(rest)
                }
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    stackHeader(LS("订阅中")).opacity(rest)
                    if active.isEmpty {
                        GroupedSection {
                            GroupedRow { EmptyAdd(text: LS("还没有订阅。也可以在交易详情里选择「加入订阅管理」。"), title: LS("添加订阅")) { editing = SubDraft(currency: store.L?.base ?? "CNY") } }
                        } header: { EmptyView() }
                        .opacity(rest)
                    } else { SubCardStack(subs: active, today: today) }
                }
                if !inactive.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                        stackHeader(LS("已暂停 / 已取消")).opacity(rest)
                        SubCardStack(subs: inactive, today: today)
                    }
                }
                statsSection(all, L, today).opacity(rest)
            }
            .padding(.horizontal, AppSpacing.content)
            .padding(.vertical, AppSpacing.control)
        }
        .refreshable { await store.refresh() }
        .listChanges(store.version)
    }

    private func stackHeader(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, AppSpacing.content)
    }

    /// a payee charged on a regular cycle: 加入 makes it a subscription; held, 忽略 (no swipe outside a List)
    private func candidateRow(_ c: SubCandidate) -> some View {
        GroupedRow {
            HStack(spacing: AppSpacing.control) {
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    Text(c.payee)
                    Text(LS("%@ · %@ 笔 · %@ 起", c.period.name, c.count, c.first)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(money(c.amount, c.currency)).monospacedDigit().sensitive()
                Button { editing = SubDraft(c) } label: { Label(LS("加入"), systemImage: "plus").labelStyle(ControlLabelStyle()) }.rowButton()
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .contentShape(.contextMenuPreview, Rectangle())
        .contextMenu {
            Button { store.ignoreCandidate(c) } label: { Label(LS("忽略"), systemImage: "eye.slash") }
                .onAppear { Learned.hold.mark() }
        }
    }

    private func tidy() {
        guard let ops = store.moveSubLinesOps(), !ops.isEmpty else { return }
        Task { await store.commit(ops, word: LS("已整理订阅记录")) }
    }

    @ViewBuilder
    private func statsSection(_ all: [Subscription], _ L: Ledger, _ today: String) -> some View {
        let active = all.filter { $0.status == .active }
        if active.count >= 2 {
            let rows = byCategory(active, L)
            let total = max(rows.reduce(0) { $0 + $1.value }, 1)
            let y = Int(today.prefix(4)) ?? 2026
            let years = (0..<3).map { String(y - $0) }
            GroupedSection {
                ForEach(Array(rows.enumerated()), id: \.element.key) { i, r in
                    if i > 0 { GroupedDivider() }
                    GroupedRow {
                        CatBar(name: acctZH(r.key) ?? leaf(r.key), sub: nil, value: r.value, frac: r.value / total,
                               share: Int((r.value / total * 100).rounded()), chevron: nil)
                    }
                }
                ForEach(years, id: \.self) { yr in
                    GroupedDivider()
                    GroupedRow {
                        LabeledContent(LS("%@ 年订阅支出", yr), value: money(all.reduce(0.0) { $0 + (toCNY(L, $1.paid(in: yr), $1.currency) ?? 0) }, L.base, 0))
                            .sensitive()
                    }
                }
            } header: {
                Text(LS("统计"))
            }
        }
    }
}

private func byCategory(_ subs: [Subscription], _ L: Ledger) -> [(key: String, value: Double)] {
    var m: [String: Double] = [:]
    for s in subs { m[catOf(s.account), default: 0] += toCNY(L, s.monthly, s.currency) ?? 0 }
    return m.sorted { $0.value > $1.value }.map { (key: $0.key, value: $0.value) }
}


// MARK: - detail

struct SubscriptionDetailView: View {
    @Environment(Store.self) var store
    let name: String
    /// opened in place from 订阅管理's stacks: closes back into them
    var close: (() -> Void)? = nil
    @State private var editingFace = false
    @State private var editing: SubDraft?
    @State private var stateChange: SubStatus?
    @State private var linking = false
    @State private var confirmDelete = false
    @State private var undoing: SubTimelineItem?
    /// the charges beyond the latest five, and the history: folded away like a transaction's postings
    @State private var showAllCharges = false
    @State private var showHistory = false
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
        let charges = Array(s.charges.reversed())
        return VStack(spacing: 0) {
            // drawn as a bank card, so outside the List (which would cut it round at the section's edge); opened in
            // place, 订阅管理 draws it, where it moves to
            if close == nil { hero(s, today: today, next: next).modifier(OpenCardPlace()) }
            details(s, today: today, next: next, alerts: alerts, charges: charges)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func details(_ s: Subscription, today: String, next: String, alerts: [SubAlert], charges: [SubCharge]) -> some View {
        List {
            infoSection(s)
            if !alerts.isEmpty {
                Section(LS("需要留意")) {
                    ForEach(alerts) { a in alertRow(a, s) }
                }
            }
            Section {
                if charges.isEmpty { Text(LS("还没有关联的扣费交易")).foregroundStyle(.secondary) }
                ForEach(showAllCharges ? charges : Array(charges.prefix(5))) { c in chargeRow(c, s) }
                if charges.count > 5 {
                    Button { withAnimation(AppMotion.standard) { showAllCharges.toggle() } } label: {
                        Label(showAllCharges ? LS("收起") : LS("查看全部 %@ 笔", charges.count), systemImage: showAllCharges ? "chevron.up" : "chevron.down")
                            .labelStyle(ControlLabelStyle())
                    }
                }
            } header: {
                Text(LS("扣费记录（%@）", s.charges.count))
            } footer: {
                Text(LS("左滑一笔扣费可「并入上一期（补差）」：计入累计已付，不算新的一期。"))
            }
            Section(LS("关联记录")) {
                NavigationLink(value: LinkDest(link: s.link)) {
                    HStack(spacing: AppSpacing.control) {
                        Label(LS("扣费链接"), systemImage: "link").labelStyle(ControlLabelStyle())
                        Spacer()
                        Text("^" + s.link).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Section {
                DisclosureGroup(isExpanded: $showHistory) {
                    ForEach(subscriptionTimeline(s)) { item in historyRow(item) }
                } label: {
                    Label(LS("历史"), systemImage: "clock.arrow.circlepath").labelStyle(ControlLabelStyle())
                }
            } footer: {
                Text(LS("左滑变更记录可撤销。「调价或更改」会新增一条带生效日期的记录，保留历史；「修正记录」直接修改最近一条，用于改正填错的内容。"))
            }
        }
        .safeAreaInset(edge: .bottom) {
            // opened in place: its actions are in ⋯, as Wallet shows a pass on its own
            if close == nil { actionBar(s) }
        }
        .modifier(HidesTabBar(on: close == nil))
        .navigationBarBackButtonHidden(close != nil)
        .toolbar {
            if let close {
                ToolbarItem(placement: .topBarLeading) {
                    Button { close() } label: { Image(systemName: "xmark") }.accessibilityLabel(LS("关闭"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) { moreMenu(s, next: next) }
        }
        .sheet(isPresented: $editingFace) {
            let face = store.subFace(s)
            FaceStyleSheet(subject: face.subject, title: s.name, tint: face.tint)
                .tint(Color.jadeInk).environment(\.locale, AppLanguage.current.locale)
        }
        .listSectionSpacing(.compact)
        .confirmationDialog(LS("删除订阅「%@」？", name), isPresented: $confirmDelete, titleVisibility: .visible) {
            let n = s.charges.filter { $0.txn.links.contains(s.link) }.count
            Button(role: .destructive) { delete(s, unlink: true) } label: { Text(n > 0 ? LS("删除，并移除 %@ 笔交易的链接", n) : LS("删除")) }
            if n > 0 { Button { delete(s, unlink: false) } label: { Text(LS("删除，保留交易上的链接")) } }
        } message: {
            Text(LS("删除这个订阅的全部记录，扣费交易本身保留。不再续费时建议改为「取消订阅」。"))
        }
        .confirmationDialog(LS("撤销这条记录？"), isPresented: Binding(get: { undoing != nil }, set: { if !$0 { undoing = nil } }), titleVisibility: .visible) {
            Button(role: .destructive) { if let u = undoing { undo(u, s) } } label: { Text(LS("撤销")) }
        } message: {
            Text(undoing.map { $0.from + " " + $0.title } ?? "")
        }
    }

    /// its card: the name and where it stands, what it costs each period, the totals
    private func hero(_ s: Subscription, today: String, next: String) -> some View {
        let statusText = s.status.name + " · " + s.statusDate + (s.until.map { $0 >= today ? " · " + LS("可用至 %@", $0) : "" } ?? "")
        let face = store.subFace(s)
        return FaceCard(subject: face.subject, title: s.name, tint: face.tint, real: true) { _ in
            VStack(alignment: .leading, spacing: AppSpacing.control) {
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    Text(s.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(s.status == .active ? LS(s.manual ? "下次续费 %@（%@）" : "下次扣费 %@（%@）", next, daysText(next, today: today)) : statusText)
                        .font(.caption).opacity(0.8).lineLimit(1)
                }
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    Text(s.period.name).font(.caption)
                    Text(money(s.amount, s.currency))
                        .heroAmount().monospacedDigit()
                        .rollingNumber(s.amount)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .sensitive()
                }
                // the totals at the card's foot
                Spacer(minLength: 0)
                Rectangle().fill(.primary.opacity(0.18)).frame(height: 1).accessibilityHidden(true)
                HStack(alignment: .top, spacing: AppSpacing.control) {
                    SubFigure(label: LS("累计已付"), value: money(s.totalPaid, s.currency, 0))
                    Spacer(minLength: 0)
                    SubFigure(label: LS("今年"), value: money(s.paid(in: String(today.prefix(4))), s.currency, 0))
                    Spacer(minLength: 0)
                    SubFigure(label: LS("扣费次数"), value: "\(s.periodCharges.count)", alignment: .trailing)
                }
            }
        }
        .grayscale(s.status == .active ? 0 : 1)
    }

    /// 分类, 付款账户, how it is paid, since when
    private func infoSection(_ s: Subscription) -> some View {
        Section {
            if !s.account.isEmpty {
                NavigationLink(value: AccountDest(name: s.account)) { LabeledContent(LS("分类"), value: acctDisplay(s.account)) }
            }
            if !s.paymentAccount.isEmpty {
                NavigationLink(value: AccountDest(name: s.paymentAccount)) {
                    LabeledContent(LS("付款账户"), value: acctDisplay(s.paymentAccount))
                }
            }
            LabeledContent(LS("扣费方式"), value: [s.manual ? LS("手动续费") : LS("自动扣费"), s.variable ? LS("金额不固定") : nil].compactMap { $0 }.joined(separator: " · "))
            LabeledContent(LS("开始于"), value: s.start)
            if let t = s.trialEnd { LabeledContent(LS("试用到期"), value: t) }
        } footer: {
            if !s.paymentAccount.isEmpty, s.lastCharge != nil { Text(LS("付款账户按最近一次扣费。")) }
        }
    }

    private func chargeRow(_ c: SubCharge, _ s: Subscription) -> some View {
        NavigationLink(value: TxDest(c.txn)) {
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                TxRow(t: c.txn, showDate: true)
                if let note = chargeNote(c, s) {
                    Text(note).font(.caption).foregroundStyle(.secondary).monospacedDigit().sensitive()
                }
            }
        }
        .rowActions {
            // a top-up of the period before, or a period of its own (refunds and the first charge aside)
            if c.topup {
                Button { setTopup(c, false, s) } label: { Label(LS("改为单独一期"), systemImage: "calendar") }.tint(Color.warn)
            } else if !c.refund, s.charges.contains(where: { !$0.refund && !$0.topup && ($0.date < c.date || ($0.date == c.date && $0.id < c.id)) }) {
                Button { setTopup(c, true, s) } label: { Label(LS("并入上一期（补差）"), systemImage: "arrow.triangle.merge") }.tint(Color.warn)
            }
            if c.txn.links.contains(s.link) {
                Button {
                    let op = subscriptionUnlinkOp(c.txn, link: s.link); Task { await store.commit([op], word: LS("已取消关联")) }
                } label: { Label(LS("取消关联"), systemImage: "link") }
                .tint(.gray)
            }
        }
    }

    private func historyRow(_ item: SubTimelineItem) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.icon) {
            Image(systemName: item.kind == .event ? icon(item.eventKind) : item.kind == .gap ? "pause.circle" : "creditcard")
                .foregroundStyle(item.kind == .gap ? Color.secondary : item.kind == .event ? Color.purple : Color.jadeInk)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                Text(item.title).font(.subheadline).sensitive()
                Text(item.to.map { item.from + " ~ " + $0 } ?? item.from).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).sensitive() }
        }
        .rowActions {
            // a change, pause, resume, cancel or skip can be taken back (not the very first line)
            if item.kind == .event, item.eventKind != .start, item.entry != nil {
                Button { undoing = item } label: { Label(LS("撤销"), systemImage: "arrow.uturn.backward") }.tint(Color.warn)
            }
        }
    }

    /// the everyday actions at the bottom, as on a transaction
    private func actionBar(_ s: Subscription) -> some View {
        ActionRow(size: .large, items: actionItems(s))
            .padding(.horizontal, AppSpacing.content)
            .padding(.top, AppSpacing.icon)
            .padding(.bottom, AppSpacing.icon)
            .background(.bar)
    }

    private func actionItems(_ s: Subscription) -> [ActionRow.Item] {
        s.status == .active ? [
            ActionRow.Item(title: s.manual ? LS("记一笔续费") : LS("记一笔扣费"), systemImage: "plus.circle", emphasis: .primary) { store.recordSubscription(s) },
            ActionRow.Item(title: LS("调价或更改"), systemImage: "slider.horizontal.3") { editing = SubDraft(s, mode: .change) },
        ] : [
            ActionRow.Item(title: LS("恢复订阅"), systemImage: "play.circle", emphasis: .primary) {
                var d = SubDraft(s, mode: .change); d.status = .active; editing = d
            },
        ]
    }

    /// everything else, as a transaction's ⋯
    private func moreMenu(_ s: Subscription, next: String) -> some View {
        Menu {
            // opened in place there is no bar under it: its buttons are here
            if close != nil {
                ForEach(Array(actionItems(s).enumerated()), id: \.offset) { _, a in
                    Button { a.action() } label: { Label(a.title, systemImage: a.systemImage) }
                }
                Button { editingFace = true } label: { Label(LS("编辑卡面"), systemImage: "paintbrush") }
                Divider()
            }
            if s.status == .active {
                Button { editing = SubDraft(dueOf: s) } label: { Label(LS("调整到期日"), systemImage: "calendar.badge.clock") }
                Button { skip(s, next) } label: { Label(LS("跳过下一期（%@）", next), systemImage: "forward.end") }
                Button { stateChange = .paused } label: { Label(LS("暂停"), systemImage: "pause.circle") }
            }
            Button { linking = true } label: { Label(LS("关联已有交易"), systemImage: "link") }
            Button { editing = SubDraft(s, mode: .correct) } label: { Label(LS("修正记录"), systemImage: "pencil") }
            Divider()
            if s.status == .active {
                Button(role: .destructive) { stateChange = .cancelled } label: { Label(LS("取消订阅"), systemImage: "xmark.circle") }
            }
            Button(role: .destructive) { confirmDelete = true } label: { Label(LS("删除订阅"), systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(LS("更多"))
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

    private func alertRow(_ a: SubAlert, _ s: Subscription) -> some View {
        let actions = alertActions(a, s)
        return VStack(alignment: .leading, spacing: AppSpacing.icon) {
            Label(a.message, systemImage: "exclamationmark.triangle").labelStyle(ControlLabelStyle()).font(.subheadline).foregroundStyle(Color.warn).sensitive()
            if !actions.isEmpty { ActionRow(size: .small, items: actions) }
        }
        .padding(.vertical, AppSpacing.detail)
    }

    private func alertActions(_ a: SubAlert, _ s: Subscription) -> [ActionRow.Item] {
        switch a.kind {
        case .priceChanged:
            guard let v = a.amount else { return [] }
            return [ActionRow.Item(title: LS("更新为 %@", money(v, s.currency)), systemImage: "arrow.clockwise", emphasis: .primary) {
                var d = SubDraft(s, mode: .change)
                d.amount = jsNumberString(v)
                d.date = a.date ?? Day.today()
                editing = d
            }]
        case .silent:
            return [
                ActionRow.Item(title: LS("补记一笔续费"), systemImage: "plus.circle", emphasis: .primary) { store.recordSubscription(s) },
                ActionRow.Item(title: LS("标记为暂停"), systemImage: "pause.circle") { stateChange = .paused },
                ActionRow.Item(title: LS("标记为取消"), systemImage: "xmark.circle", emphasis: .destructive) { stateChange = .cancelled },
            ]
        case .chargedWhileInactive:
            return [ActionRow.Item(title: LS("恢复订阅"), systemImage: "arrow.counterclockwise", emphasis: .primary) {
                var d = SubDraft(s, mode: .change)
                d.status = .active
                d.date = a.date ?? Day.today()
                editing = d
            }]
        case .trialEnding:
            return []
        }
    }

    private func delete(_ s: Subscription, unlink: Bool) {
        let ops = subscriptionDeleteOps(s, unlink: unlink)
        // opened in place: 订阅管理 goes back to its stacks by itself once it is gone
        Task { if await store.commit(ops, word: LS("已删除")), close == nil { dismiss() } }
    }

    private func undo(_ item: SubTimelineItem, _ s: Subscription) {
        guard let op = subscriptionUndoOp(item, s) else { return }
        undoing = nil
        Task { await store.commit([op], word: LS("已撤销")) }
    }

    /// "¥122.00 + 补差 ¥20.00 = ¥142.00" under a period's charge; "补差，并入 2023-08-07 这一期" under a top-up
    private func chargeNote(_ c: SubCharge, _ s: Subscription) -> String? {
        if c.topup {
            return s.period(of: c).map { LS("补差，并入 %@ 这一期", $0.date) } ?? LS("补差")
        }
        let ups = s.topups(of: c)
        guard !c.refund, !ups.isEmpty else { return nil }
        let sum = c.amount + ups.reduce(0) { $0 + $1.amount }
        return ([money(c.amount, s.currency)] + ups.map { LS("补差 %@", money($0.amount, s.currency)) }).joined(separator: " + ")
            + " = " + money(sum, s.currency)
    }

    /// mark a charge as a top-up of the period before (`topup: TRUE`), or take the mark off
    private func setTopup(_ c: SubCharge, _ on: Bool, _ s: Subscription) {
        guard let op = subscriptionTopupOp(c, on, s) else { return }
        Task { await store.commit([op], word: on ? LS("已并入上一期") : LS("已改为单独一期")) }
    }

    private func skip(_ s: Subscription, _ due: String) {
        let text = subscriptionSkipText(s.name, due: due)
        guard let ops = store.makeOps(text, extra: OpExtra(label: LS("跳过一期：%@ %@", s.name, due)), single: false) else { return }
        Task { await store.commit(ops, word: LS("已跳过 %@ 这一期", due)) }
    }
}

// MARK: - pause / cancel

/// hides the tab bar on a page pushed over it; not on one opened in place, which would move the page under it
private struct HidesTabBar: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.toolbar(.hidden, for: .tabBar) } else { content }
    }
}

struct SubStateSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let name: String
    let status: SubStatus
    @State private var date = Day.today()
    @State private var keepUntil = true
    @State private var until = Day.today()
    @State private var loaded = false

    @State private var saving = false
    @State private var closeRequested = false
    @State private var baseline: [String]?

    private var state: [String] { [date, String(keepUntil), until] }
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
            .disabled(saving)
            .protectUnsavedChanges(dirty: baseline.map { $0 != state } ?? false, busy: saving,
                requested: $closeRequested, discard: { dismiss() }, close: { dismiss() })
            .onAppear { if baseline == nil { baseline = state } }
            .onChange(of: store.cfg.id) { _, _ in dismiss() }
            .navigationTitle(status == .paused ? LS("暂停订阅") : LS("取消订阅"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { closeRequested = true } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) { Button { save() } label: { SaveLabel() }.disabled(saving) }
            }
        }
        .formSheet()
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let s = store.subs.first(where: { $0.name == name }), let c = s.lastCharge {
                until = max(Day.shift(s.period.add(c.date, 1), -1), date)
            }
            baseline = state
        }
    }

    private var text: String {
        subscriptionStateText(name, status, date: date, until: status == .cancelled && keepUntil ? until : nil)
    }

    private func save() {
        guard !saving else { return }
        guard let ops = store.makeOps(text, extra: OpExtra(label: (status == .paused ? LS("暂停订阅：%@") : LS("取消订阅：%@")).replacingOccurrences(of: "%@", with: name)), single: false) else { return }
        let ledgerID = store.cfg.id
        saving = true
        Task {
            defer { saving = false }
            guard store.cfg.id == ledgerID else { return }
            guard store.cfg.id == ledgerID else { return }
            await store.commit(ops, word: status == .paused ? LS("已暂停") : LS("已取消订阅"), closing: { dismiss() }) }
    }
}

// MARK: - link existing transactions

struct SubLinkSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var picked = Set<Int>()

    @State private var saving = false
    @State private var closeRequested = false
    @State private var baseline: [String]?

    private var state: [String] { [picked.sorted().map(String.init).joined(separator: ",")] }
    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L, let s = store.subs.first(where: { $0.name == name }) {
                    TxPicker(hint: SubHint(s), exclude: Set(s.charges.map { $0.txn.id }), picked: $picked)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button { save(L, s) } label: { Label(LS("关联 %@ 笔", picked.count), systemImage: "link").labelStyle(ControlLabelStyle()) }.fontWeight(.semibold).disabled(picked.isEmpty || saving)
                            }
                        }
                } else { PageLoading() }
            }
            .disabled(saving)
            .protectUnsavedChanges(dirty: baseline.map { $0 != state } ?? false, busy: saving,
                requested: $closeRequested, discard: { dismiss() }, close: { dismiss() })
            .onAppear { if baseline == nil { baseline = state } }
            .onChange(of: store.cfg.id) { _, _ in dismiss() }
            .navigationTitle(LS("关联已有交易"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { closeRequested = true } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } } }
        }
    }

    private func save(_ L: Ledger, _ s: Subscription) {
        guard !saving else { return }
        let txns = picked.sorted().compactMap { $0 < L.txns.count ? L.txns[$0] : nil }
        let ledgerID = store.cfg.id
        saving = true
        Task {
            defer { saving = false }
            guard store.cfg.id == ledgerID else { return }
            guard let ops = await store.linkOps(txns, link: s.link, label: LS("关联订阅：%@ %@ 笔", s.name, txns.count)), !ops.isEmpty else { return }
            guard store.cfg.id == ledgerID else { return }
            await store.commit(ops, word: LS("已关联 %@ 笔", txns.count), closing: { dismiss() })
        }
    }
}

// MARK: - edit

struct SubEditSheet: View {
    /// return moves on: name → currency → payee (the amount has a number pad, without a return key)
    private enum Field { case name, currency, payee }
    @FocusState private var field: Field?
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: SubDraft
    @State private var picking: PickTarget?

    enum PickTarget: String, Identifiable { case account, funding; var id: String { rawValue } }

    @State private var saving = false
    @State private var closeRequested = false
    @State private var baseline: [String]?

    private var state: [String] { [draft.name, draft.amount, draft.currency, String(describing: draft.period), draft.start, draft.date, draft.account, draft.funding, draft.payee, String(draft.extended), draft.next, String(draft.trial), draft.trialEnd, String(describing: draft.status), draft.link, String(draft.manual), String(draft.variable), draft.picked.sorted().map(String.init).joined(separator: ",")] }
    var body: some View {
        NavigationStack {
            Form {
                if draft.dueOnly { dueSections } else {
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
                            .focused($field, equals: .name).submitLabel(.next).onSubmit { field = .currency }
                    }
                    LabeledContent(LS("金额")) {
                        HStack(spacing: AppSpacing.icon) {
                            TextField("0.00", text: $draft.amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing).font(.body.monospacedDigit())
                            TextField("CNY", text: $draft.currency).frame(width: 52).multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled().foregroundStyle(.secondary)
                                .focused($field, equals: .currency).submitLabel(.next).onSubmit { field = .payee }
                        }
                    }
                    LabeledContent(LS("收付款方")) {
                        TextField(LS("可选"), text: $draft.payee).multilineTextAlignment(.trailing)
                            .focused($field, equals: .payee).submitLabel(.done)
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
                        LabeledContent { Text(draft.account.isEmpty ? LS("选择") : acctDisplay(draft.account)).foregroundStyle(.secondary) } label: { Label(LS("支出科目"), systemImage: "building.columns").labelStyle(ControlLabelStyle()) }
                    }
                    .foregroundStyle(.primary)
                    Button { picking = .funding } label: {
                        LabeledContent { Text(draft.funding.isEmpty ? LS("选择") : acctDisplay(draft.funding)).foregroundStyle(.secondary) } label: { Label(LS("付款账户"), systemImage: "building.columns").labelStyle(ControlLabelStyle()) }
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text(LS("新记的交易科目、收付款方一致且金额相近时，会自动关联到这个订阅。付款账户只是默认值，每次扣费用哪个账户以交易为准，「记一笔」时沿用最近一次扣费的账户。"))
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
                        Text(LS("把过去的扣费交易关联到这个订阅，可搜索收付款方、摘要、金额或日期。"))
                    }
                }
                if let t = draft.text {
                    Section(LS("将写入")) { MonoText(text: t) }
                }
                }
            }
            .disabled(saving)
            .protectUnsavedChanges(dirty: baseline.map { $0 != state } ?? false, busy: saving,
                requested: $closeRequested, discard: { dismiss() }, close: { dismiss() })
            .onAppear { if baseline == nil { baseline = state } }
            .onChange(of: store.cfg.id) { _, _ in dismiss() }
            .keyboardDone()
            .navigationTitle(draft.dueOnly ? LS("调整到期日") : draft.mode == .new ? LS("添加订阅") : draft.mode == .correct ? LS("修正记录")
                             : draft.original?.status != .active ? LS("恢复订阅") : LS("调价或更改"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { closeRequested = true } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { SaveLabel() }
                        .disabled(saving || draft.sub == nil || nameTaken || (draft.dueOnly && (draft.next <= draft.date || draft.next == current)))
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

    /// the next charge as it is now
    private var current: String? { draft.original.map { $0.nextCharge(onOrAfter: Day.today()) } }

    /// 调整到期日: when the paid period really ends (the provider gave extra time, or moved the renewal)
    @ViewBuilder
    private var dueSections: some View {
        Section {
            if let c = current { LabeledContent(LS("当前下次扣费"), value: c) }
            DatePicker(LS("调整为"), selection: dateBinding($draft.next), displayedComponents: .date)
        } footer: {
            Text(LS("本期实际用到的日期与周期不一致时（服务商延长、补偿或改了续费日），把下次扣费日改到实际日期，之后按原周期（%@）继续计算。", draft.period.name))
        }
        Section {
            DatePicker(LS("记录日期"), selection: dateBinding($draft.date), displayedComponents: .date)
        } footer: {
            if draft.next <= draft.date { Text(LS("下次扣费日要晚于记录日期")).foregroundStyle(Color.warn) }
            else { Text(LS("新增一条带日期的记录，价格和历史不变；在「历史」里左滑可撤销。")) }
        }
        if draft.next > draft.date, let t = draft.text {
            Section(LS("将写入")) { MonoText(text: t) }
        }
    }

    /// another subscription already uses this name
    private var nameTaken: Bool { draft.nameTaken(store.subs) }

    private func save() {
        guard !saving else { return }
        // a new subscription gets a link no other subscription uses ("sub-icloud-2")
        if draft.mode == .new && draft.link.isEmpty {
            draft.link = uniqueSubscriptionLink(draft.name.trimmed, taken: store.ownedSubLinks)
        }
        guard let s = draft.sub, draft.text != nil, !nameTaken else { return }
        let label = draft.changeSummary
        let ledgerID = store.cfg.id
        saving = true
        Task {
            defer { saving = false }
            guard store.cfg.id == ledgerID else { return }
            guard var ops = draft.ops(insert: { store.makeOps($0, extra: OpExtra(label: $1), single: false) }) else { return }
            if draft.mode == .new {
                let txns = draft.picked.sorted().compactMap { id in store.L.flatMap { id < $0.txns.count ? $0.txns[id] : nil } }
                guard let linked = await store.linkOps(txns, link: s.link, label: nil) else { return }
                ops += linked
            }
            guard store.cfg.id == ledgerID else { return }
            await store.commit(ops, word: draft.mode == .new ? LS("已添加订阅") : label, closing: { dismiss() })
        }
    }
}
