import SwiftUI
import LedgerKit

/// points at a transaction by position, and by its text so it survives a re-sync
struct TxDest: Hashable {
    let id: Int
    let key: String
    init(_ t: Entry) { id = t.id; key = TxDest.key(t) }
    static func key(_ t: Entry) -> String { t.date + "\u{1}" + t.src }
}
struct AccountDest: Hashable { let name: String }
struct EditDest: Hashable {
    let id: Int
    let key: String
    init(_ t: Entry) { id = t.id; key = TxDest.key(t) }
}

extension Store {
    func txn(_ id: Int, key: String) -> Entry? {
        guard let L = L else { return nil }
        if id >= 0, id < L.txns.count, TxDest.key(L.txns[id]) == key { return L.txns[id] }
        if let t = L.txns.first(where: { TxDest.key($0) == key }) { return t }
        // edited in place (a link added or removed): follow it to its new text
        var k = key, hops = 0
        while let next = Store.movedKeys[Store.normKey(k)], hops < 8 { k = next; hops += 1 }
        guard hops > 0 else { return nil }
        let want = Store.normKey(k)
        return L.txns.first { Store.normKey(TxDest.key($0)) == want }
    }

    /// old text → new text of transactions changed in place, so open pages keep showing them
    static var movedKeys: [String: String] = [:]
    static func normKey(_ k: String) -> String { normEntryText(k) }
    /// before `ops` are applied (the ledger as it is): every transaction they rewrite or move
    func noteMoved(_ ops: [Op]) {
        guard let L = L else { return }
        for m in movedEntries(ops, L) {
            Store.movedKeys[Store.normKey(m.oldDate + "\u{1}" + m.old)] = m.newDate + "\u{1}" + m.new
        }
    }
}

struct TxRow: View {
    @EnvironmentObject var store: Store
    let t: Entry
    var account: String? = nil
    var balance: String? = nil
    var showDate = false

    var body: some View {
        if let L = store.L, let D = store.D {
            let c = classify(t, L)
            let cat = t.postings.first { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(t.payee.isEmpty ? (t.narration.isEmpty ? LS("（无收付款方）") : t.narration) : t.payee).lineLimit(1)
                        if !t.payee.isEmpty && !t.narration.isEmpty { Text(t.narration).foregroundStyle(.secondary).lineLimit(1) }
                        if t.flag == "!" { Tag(text: LS("待确认"), warn: true) }
                        if t.synthetic { Tag(text: "pad") }
                        ForEach(t.tags.filter { $0 != "transfer" && $0 != "fx" }, id: \.self) { Tag(text: "#" + $0) }
                    }
                    .font(.body)
                    Text((showDate ? t.date + "  " : "") + (cat.map { acctDisplay($0.account) } ?? moneyRoute(t).map { D.shortName($0) }.joined(separator: " → "))
                         + withWhom(t))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    amountView(c)
                    if let b = balance { Text(b).font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive() }
                }
            }
        }
    }

    /// " · 五姨、王五": who the personal receivable lines are with
    private func withWhom(_ t: Entry) -> String {
        var names: [String] = []
        for p in t.postings where isPersonal(p.account) {
            if let n = postingPerson(p), !names.contains(n) { names.append(n) }
        }
        return names.isEmpty ? "" : " · " + names.joined(separator: LS("、"))
    }

    @ViewBuilder
    private func amountView(_ c: Classified) -> some View {
        if let a = account {
            let ps = t.postings.filter { $0.account == a || $0.account.hasPrefix(a + ":") }
            let byC = Dictionary(grouping: ps, by: { $0.currency ?? "" }).mapValues { list in list.reduce(0.0) { $0 + ($1.units ?? 0) } }
            HStack(spacing: 6) {
                ForEach(byC.keys.sorted(), id: \.self) { cc in Amount(n: byC[cc]!, c: cc, signed: true, color: true) }
            }
        } else if c.kind == .transfer {
            Text(money(c.amount, c.currency ?? "CNY")).monospacedDigit().foregroundStyle(.secondary).sensitive()
        } else {
            // in the transaction's own currency (as on the receipt), not converted; what the account was
            // charged in another currency underneath, for checking against the bank
            let own = sums(t.postings.filter { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") }, negate: true)
            let paid = sums(t.postings.filter { !$0.account.hasPrefix("Expenses:") && !$0.account.hasPrefix("Income:") && !$0.account.hasPrefix("Equity:") }, negate: false)
                .filter { p in !own.contains { $0.0 == p.0 } }
            VStack(alignment: .trailing, spacing: 1) {
                ForEach(own, id: \.0) { x in Amount(n: x.1, c: x.0, signed: true, color: true) }
                ForEach(paid, id: \.0) { x in Text(money(x.1, x.0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive() }
            }
        }
    }

    private func sums(_ ps: [Posting], negate: Bool) -> [(String, Double)] { postingSums(ps, negate: negate) }
}

/// per currency, in the order they first appear (amounts too small to show left out)
func postingSums(_ ps: [Posting], negate: Bool) -> [(String, Double)] {
    var order: [String] = [], m: [String: Double] = [:]
    for p in ps {
        guard let u = p.units, let c = p.currency else { continue }
        if m[c] == nil { order.append(c) }
        m[c, default: 0] += negate ? -u : u
    }
    return order.compactMap { c in abs(m[c]!) > 0.004 ? (c, roundTo(m[c]!, 2)) : nil }
}

struct Tag: View {
    let text: String
    var warn = false
    var body: some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(warn ? Color.orange.opacity(0.18) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(warn ? Color.orange : Color.secondary)
            .lineLimit(1)
    }
}

struct JournalView: View {
    @EnvironmentObject var store: Store
    @State private var path = NavigationPath()
    @State private var q = ""
    @State private var limit = 150
    @State private var selecting = false
    @State private var selected: Set<String> = []
    /// swiped to delete, waiting for the confirmation
    @State private var deleting: Entry?
    @State private var batch: BatchMode?
    /// list or month calendar (remembered on this device)
    @AppStorage("ledger.journal.calendar") private var showCalendar = false
    /// the quick filters on (本月, 大额, 待确认, 报销), added to what is typed
    @State private var quick: [QuickFilter] = []
    /// saving the filters as a quick search
    @State private var savingFilter: QuickSearchEdit?

    enum QuickFilter: String, CaseIterable, Identifiable {
        case month, large, pending, reimb
        var id: String { rawValue }
        var title: String {
            switch self {
            case .month: return LS("本月")
            case .large: return LS("大额")
            case .pending: return LS("待确认")
            case .reimb: return LS("报销")
            }
        }
        var icon: String {
            switch self {
            case .month: return "calendar"
            case .large: return "arrow.up.circle"
            case .pending: return "exclamationmark.circle"
            case .reimb: return "doc.text"
            }
        }
        /// the same in the search box's own words
        func query(_ store: Store) -> String {
            switch self {
            case .month: return "本月"
            case .large: return ">" + jsNumberString(store.largeExpense)
            case .pending: return "!"
            case .reimb: return "账户:" + store.receivable
            }
        }
    }

    /// what is searched: the box and the quick filters together
    private var fullQuery: String {
        ([q.trimmed] + quick.map { $0.query(store) }).filter { !$0.isEmpty }.joined(separator: " ")
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let L = store.L {
                    if showCalendar { JournalCalendar(L: L, entries: search(L), account: account) } else { list(L) }
                } else { ProgressView() }
            }
            .navigationTitle(LS("明细"))
            .toolbar {
                StandardToolbar()
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { withAnimation { showCalendar.toggle(); selecting = false; selected = [] } } label: {
                        Image(systemName: showCalendar ? "list.bullet" : "calendar")
                    }
                    .accessibilityLabel(showCalendar ? LS("列表") : LS("日历"))
                    if !showCalendar {
                        Button(selecting ? LS("完成") : LS("选择")) {
                            withAnimation { selecting.toggle(); selected = [] }
                        }
                    }
                }
            }
            .topBar { if !selecting { QuickSearchBar(q: $q) } }
            .safeAreaInset(edge: .bottom) { if selecting { batchBar } }
            .sheet(item: $savingFilter) { e in QuickSearchSheet(edit: e) }
            .sheet(item: $batch) { m in
                BatchEditSheet(entries: selectedEntries, mode: m) { selecting = false; selected = [] }
            }
            .confirmationDialog(deleting.map { LS("删除 %@ %@？", $0.date, [$0.payee, $0.narration].filter { !$0.isEmpty }.joined(separator: " ")) } ?? "",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { t in
                Button(LS("删除"), role: .destructive) { Task { await store.deleteEntry(t) } }
            } message: { _ in
                Text(LS("删除后可在「最近改动」里撤回。"))
            }
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: LS("收付款方、摘要、科目、对方、#标签、金额、2026-09"))
            .searchSuggestions { if q.isEmpty { searchHelp } }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: q) { _, _ in limit = 150 }
            .onChange(of: quick) { _, _ in limit = 150 }
            .navigationDestination(for: TxDest.self) { TxDetailView(dest: $0).privacyToolbar() }
            .subscriptionDestinations()
            .navigationDestination(for: EditDest.self) { EditTxView(dest: $0) }
            .navigationDestination(for: AccountDest.self) { RegisterView(account: $0.name).privacyToolbar() }
        }
        .onChange(of: store.popToken) { _, _ in path = NavigationPath() }
        .task {
            if let q = store.demoEnv["LEDGER_QUERY"] { self.q = q }
            if let f = store.demoEnv["LEDGER_FILTERS"] { quick = f.split(separator: ",").compactMap { QuickFilter(rawValue: String($0)) } }
            if store.demoEnv["LEDGER_SELECT"] != nil, let L = store.L {
                selecting = true
                selected = Set(search(L).prefix(4).map { TxDest.key($0) })
            }
            if let l = store.demoEnv["LEDGER_OPEN_LINK"], let L = store.L, path.isEmpty,
               let t = L.txns.first(where: { $0.links.contains(l) }) {
                path.append(TxDest(t))
            }
            if store.demoEnv["LEDGER_OPEN_TX"] != nil, let L = store.L, path.isEmpty {
                let id = L.txns.lastIndex(where: { isComplex($0) && !$0.synthetic }) ?? L.txns.count - 1
                path.append(TxDest(L.txns[id]))
            }
        }
    }

    private var selectedEntries: [Entry] {
        guard let L = store.L else { return [] }
        return L.txns.filter { !$0.synthetic && selected.contains(TxDest.key($0)) }
    }

    private var batchBar: some View {
        HStack(spacing: 10) {
            Button {
                if let L = store.L {
                    let keys = search(L).prefix(limit).filter { !$0.synthetic }.map { TxDest.key($0) }
                    selected = selected.count >= keys.count ? [] : Set(keys)
                }
            } label: { Text(LS("全选")).font(.subheadline) }
            Text(LS("已选 %@ 笔", selected.count)).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(BatchMode.allCases) { m in Button(m.name) { batch = m } }
            } label: {
                Label(LS("批量编辑"), systemImage: "square.and.pencil").font(.subheadline.weight(.semibold))
            }
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var account: String? {
        get { store.journalAccount }
        nonmutating set { store.journalAccount = newValue }
    }

    @ViewBuilder
    private func list(_ L: Ledger) -> some View {
        let matches = search(L)
        let shown = Array(matches.prefix(limit))
        let sums = totals(matches, L)
        let days = groupByDay(shown)
        let filtered = !quick.isEmpty || account != nil || !q.trimmed.isEmpty
        List {
            Section {
                // the quick filters, then the tags people look for
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(QuickFilter.allCases) { f in
                            let on = quick.contains(f)
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { if on { quick.removeAll { $0 == f } } else { quick.append(f) } }
                            } label: {
                                Label(f.title, systemImage: f.icon)
                                    .font(.subheadline.weight(on ? .semibold : .regular))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .foregroundStyle(on ? Color.onJade : Color.primary)
                                    .background(on ? Color.jade : Color(.tertiarySystemFill), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(["#refund", "#transfer", "#fx", "#reimbursed"], id: \.self) { x in
                            Chip(label: x, selected: q.trimmed == x) { q = q.trimmed == x ? "" : x }
                        }
                    }
                }
                if filtered {
                    // what is on, each with its ✕, and 清除 for all of it
                    HStack(alignment: .top) {
                        FlowChips(items: conditionChips())
                        Spacer(minLength: 4)
                        Button(LS("清除")) { withAnimation { quick = []; account = nil; q = "" } }
                            .font(.subheadline.weight(.medium)).foregroundStyle(Color.jade).buttonStyle(.plain)
                    }
                }
            }
            if filtered {
                resultCard(matches, sums)
            } else {
                Section {
                    HStack {
                        Text(LS("%@ 笔", matches.count)).foregroundStyle(.secondary)
                        Spacer()
                        Group {
                            if sums.0 != 0 { Text(LS("支出 ") + money(sums.0)) }
                            if sums.1 != 0 { Text(LS("收入 ") + money(sums.1)) }
                        }
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                    }
                    .font(.footnote)
                }
            }
            ForEach(days, id: \.0) { group in
                daySection(group.0, group.1, L)
            }
            if matches.count > shown.count {
                Button(LS("加载更多（%@ 笔）", min(300, matches.count - shown.count))) { limit += 300 }.frame(maxWidth: .infinity)
            }
            if matches.isEmpty { Text(LS("无匹配交易")).foregroundStyle(.secondary) }
        }
        .listStyle(.insetGrouped)
    }

    /// how to search, while the box is empty: tap an example to start from it
    @ViewBuilder private var searchHelp: some View {
        let month = Day.ym(Day.today()), prev = Day.addMonth(Day.ym(Day.today()), -1)
        let examples: [(String, String)] = [
            ("\(prev) \(month)", LS("两个月份之间（也可写 %@）", prev + "~" + month)),
            ("\(month) 科目:餐饮", LS("这个月、某个科目：几个条件用空格隔开，要同时满足")),
            ("账户:招商 >100", LS("某个账户里大于 100 的（账户名或显示名称都行）")),
            ("payee:滴滴 -加班", LS("收付款方是滴滴，排除备注里有「加班」的")),
            ("\(Day.today().prefix(4))-Q3", LS("一个季度；也可只写年份 %@", String(Day.today().prefix(4)))),
            ("对方:王五", LS("和某人的往来")),
            ("#trip", LS("带某个标签；^ 开头找链接，! 找待确认")),
            ("#出差|#旅行", LS("用 | 表示任一：带其中一个标签就算；科目:餐饮|交通 也行")),
            ("本月 科目:餐饮", LS("本月、上月、本周、今年、近30天按今天计算，适合存成快速搜索")),
        ]
        if store.quickSearches.isEmpty {
            Label(LS("搜索后点「保存」，即可加为快速搜索"), systemImage: "bookmark").font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(examples, id: \.0) { e in
            VStack(alignment: .leading, spacing: 2) {
                Text(e.0).font(.body.monospaced())
                Text(e.1).font(.caption).foregroundStyle(.secondary)
            }
            .searchCompletion(e.0 + " ")
        }
    }

    private func search(_ L: Ledger) -> [Entry] {
        var out: [Entry] = []
        let a = account
        let query = TxQuery(fullQuery)
        for t in L.txns.reversed() {
            if let a = a, !t.postings.contains(where: { $0.account == a || $0.account.hasPrefix(a + ":") }) { continue }
            if query.matches(t, L) { out.append(t) }
        }
        return out
    }

    /// the conditions on, to take off one by one
    private func conditionChips() -> [(String, () -> Void)] {
        var out: [(String, () -> Void)] = []
        if let a = account { out.append((acctDisplay(a), { account = nil })) }
        for f in quick { out.append((f == .large ? LS("超过 %@", money(store.largeExpense, store.L?.base ?? "CNY", 0)) : f.title, { quick.removeAll { $0 == f } })) }
        if !q.trimmed.isEmpty { out.append(("“\(q.trimmed)”", { q = "" })) }
        return out
    }

    /// 筛选结果: how many, spent and received, over which days; saved as a quick search from here
    private func resultCard(_ matches: [Entry], _ sums: (Double, Double)) -> some View {
        let first = matches.last?.date, last = matches.first?.date
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(LS("筛选结果 · %@ 笔", matches.count)).font(.headline)
                    Spacer()
                    if account == nil, !fullQuery.isEmpty, !store.quickSearches.contains(where: { $0.query.trimmed == fullQuery }) {
                        Button(LS("保存为常用筛选")) { savingFilter = QuickSearchEdit(index: nil, name: "", query: fullQuery) }
                            .font(.subheadline).foregroundStyle(Color.jade).buttonStyle(.plain)
                    }
                }
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LS("支出合计")).font(.caption).foregroundStyle(.secondary)
                        Text(money(sums.0)).font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(Color.jade)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider().frame(height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LS("收入合计")).font(.caption).foregroundStyle(.secondary)
                        Text(money(sums.1)).font(.title3.weight(.bold).monospacedDigit())
                    }
                    .padding(.leading, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .sensitive()
                if let f = first, let l = last {
                    Text(f == l ? Day.dayLabel(f) : Day.dayLabel(f) + " — " + Day.dayLabel(l)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func totals(_ ts: [Entry], _ L: Ledger) -> (Double, Double) {
        var out = 0.0, inn = 0.0
        for t in ts {
            let c = classify(t, L)
            switch c.kind {
            case .expense, .refund: out -= c.amount
            case .income: inn += c.amount
            default: break
            }
        }
        return (out, inn)
    }

    private func daySection(_ day: String, _ ts: [Entry], _ L: Ledger) -> some View {
        var out = 0.0
        for x in ts {
            let c = classify(x, L)
            if c.kind == .expense || c.kind == .refund { out -= c.amount }
        }
        let year = day.prefix(4) != Day.today().prefix(4) ? " " + day.prefix(4) : ""
        return Section {
            ForEach(ts, id: \.id) { t in
                if selecting {
                    let key = TxDest.key(t)
                    Button {
                        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected.contains(key) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected.contains(key) ? Color.jade : Color.secondary)
                            TxRow(t: t, account: account)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(t.synthetic)
                } else {
                    NavigationLink(value: TxDest(t)) { TxRow(t: t, account: account) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !t.synthetic {
                                Button(role: .destructive) { deleting = t } label: { Label(LS("删除"), systemImage: "trash") }
                            }
                        }
                }
            }
        } header: {
            HStack {
                Text(Day.dayLabel(day) + year)
                Spacer()
                if out != 0 { Text(money(out)).monospacedDigit().sensitive() }
            }
        }
    }

    private func groupByDay(_ ts: [Entry]) -> [(String, [Entry])] {
        var out: [(String, [Entry])] = []
        for t in ts {
            if let last = out.last, last.0 == t.date { out[out.count - 1].1.append(t) } else { out.append((t.date, [t])) }
        }
        return out
    }
}

// MARK: - detail

struct TxDetailView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let dest: TxDest
    @State private var subDraft: SubDraft?
    @State private var subPick: Entry?
    @State private var ordering: Entry?
    /// the form can't hold all of this entry: edit its source
    @State private var visualUnavailable = false
    @State private var goSource = false
    /// the subscription form to open once the picker has gone
    @State private var nextSub: SubDraft?
    @State private var linkPick: LinkPick?
    @State private var linkRemoval: LinkPick?
    @State private var confirmDelete = false
    /// a subscription opened from the ⋯ menu
    @State private var subOpen: String?

    /// the postings' categories and accounts, folded away under the summary
    @State private var showPostings = false
    @State private var showSource = false

    var body: some View {
        if let L = store.L, let D = store.D, let t = store.txn(dest.id, key: dest.key) {
            List {
                hero(t, L)
                infoSection(t, L, D)
                if !t.links.isEmpty {
                    // links: open one to see everything it ties together
                    Section(LS("关联记录")) {
                        ForEach(t.links, id: \.self) { l in
                            let n = (D.byLink[l] ?? []).filter { !$0.synthetic }.count
                            NavigationLink(value: LinkDest(link: l)) {
                                HStack {
                                    Label(LinkRole.of(l).title, systemImage: "link")
                                    Spacer()
                                    Text("^" + l + " · " + LS("%@ 笔", n)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                LinkIssueSection(t: t, pick: $linkPick, subPick: $subPick, removing: $linkRemoval)
                LinkGroupsSection(t: t, L: L, D: D)
                if !t.synthetic { AttachmentsSection(t: t) }
                Section {
                    DisclosureGroup(isExpanded: $showPostings) {
                        ForEach(Array(t.postings.enumerated()), id: \.offset) { pair in PostingRow(p: pair.element) }
                        ForEach(t.meta.items, id: \.0) { item in LabeledContent(item.0, value: item.1.display).font(.subheadline) }
                    } label: {
                        Label(LS("分录详情"), systemImage: "list.bullet.rectangle")
                    }
                    DisclosureGroup(isExpanded: $showSource) {
                        MonoText(text: t.src)
                        Text("\(t.file):\(t.line)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    } label: {
                        Label(LS("Beancount 源文本"), systemImage: "doc.plaintext")
                    }
                }
                if t.synthetic {
                    Section {
                        Text(LS("此交易由 pad 指令自动生成，如需调整请修改对应的 pad 或余额断言。")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .listSectionSpacing(.compact)
            .safeAreaInset(edge: .bottom) { if !t.synthetic { actionBar(t, L, D) } }
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { moreMenu(t, L) }
            }
            .confirmationDialog(LS("删除 %@ %@？", t.date, [t.payee, t.narration].filter { !$0.isEmpty }.joined(separator: " ")),
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(LS("删除"), role: .destructive) { Task { await store.deleteEntry(t) } }
            } message: {
                Text(LS("删除后可在「最近改动」里撤回。"))
            }
            .navigationTitle(LS("交易详情"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $subDraft) { SubEditSheet(draft: $0) }
            .sheet(item: $ordering) { DayOrderSheet(date: $0.date, file: $0.file) }
            .navigationDestination(item: Binding(get: { subOpen.map { SubDetailDest(name: $0) } }, set: { subOpen = $0?.name })) { SubscriptionDetailView(name: $0.name) }
            .sheet(item: $linkPick) { LinkPickSheet(pick: $0) }
            .linkRemovalDialog($linkRemoval, store: store)
            .navigationDestination(isPresented: $goSource) {
                if let t = store.txn(dest.id, key: dest.key) { EditTxView(dest: EditDest(t)) }
            }
            .alert(LS("这笔请编辑源文本"), isPresented: $visualUnavailable) {
                Button(LS("编辑源文本")) { goSource = true }
                Button(LS("取消"), role: .cancel) {}
            } message: {
                Text(LS("这笔交易有表单表达不了的内容（注释、成本批次、多个价格等），用表单保存会改掉它们，请直接编辑源文本。"))
            }
            .sheet(item: $subPick, onDismiss: {
                if let d = nextSub { nextSub = nil; subDraft = d }
            }) { e in
                SubPickSheet(t: e) { if let L = store.L { nextSub = SubDraft(e, L) } }
            }
        } else {
            Text(LS("该交易已不存在")).foregroundStyle(.secondary)
        }
    }

    /// the category's icon, who, how much, the kind and the day, the category
    private func hero(_ t: Entry, _ L: Ledger) -> some View {
        let c = classify(t, L)
        let cat = t.postings.first { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") }?.account
        let own = postingSums(t.postings.filter { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") }, negate: true)
        let paid = postingSums(t.postings.filter { !$0.account.hasPrefix("Expenses:") && !$0.account.hasPrefix("Income:") && !$0.account.hasPrefix("Equity:") }, negate: false)
            .filter { p in !own.contains { $0.0 == p.0 } }
        let kindLabel: String = {
            switch c.kind {
            case .expense: return LS("支出")
            case .refund: return LS("退款")
            case .income: return LS("收入")
            case .transfer: return LS("转账")
            }
        }()
        let icon = cat.map { store.catIcon(catOf($0)) } ?? "arrow.left.arrow.right"
        return Section {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(Color.jade)
                    .frame(width: 60, height: 60)
                    .background(Color.jade.opacity(0.13), in: Circle())
                Text(t.payee.isEmpty ? (t.narration.isEmpty ? LS("交易") : t.narration) : t.payee)
                    .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Group {
                    if c.kind == .transfer {
                        Text(money(c.amount, c.currency ?? L.base))
                    } else {
                        ForEach(own, id: \.0) { x in Text(signedMoney(x.1, x.0)).foregroundStyle(x.1 >= 0 ? Color.gain : Color.primary) }
                    }
                }
                .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .sensitive()
                ForEach(paid, id: \.0) { x in
                    Text(LS("实付 %@", money(x.1, x.0))).font(.footnote.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                }
                HStack(spacing: 6) {
                    Text(kindLabel + " · " + t.date)
                    if t.flag == "!" { Tag(text: LS("待确认"), warn: true) }
                }
                .font(.subheadline).foregroundStyle(.secondary)
                if let a = cat {
                    Label(acctDisplay(a), systemImage: icon)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .foregroundStyle(Color.jade)
                        .background(Color.jade.opacity(0.12), in: Capsule())
                }
                if !t.tags.isEmpty {
                    HStack { ForEach(t.tags, id: \.self) { Tag(text: "#" + $0) } }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .cardRow()
        }
    }

    /// 付款账户 / 收款账户, 分类, 日期, 备注
    @ViewBuilder
    private func infoSection(_ t: Entry, _ L: Ledger, _ D: Derived) -> some View {
        let c = classify(t, L)
        let accounts = moneyRoute(t).filter { !$0.hasPrefix("Expenses:") && !$0.hasPrefix("Income:") && !$0.hasPrefix("Equity:") }
        let cats = t.postings.map { $0.account }.filter { $0.hasPrefix("Expenses:") || $0.hasPrefix("Income:") }
        Section {
            ForEach(Array(accounts.enumerated()), id: \.offset) { i, a in
                let label = c.kind == .transfer ? (i == 0 ? LS("转出账户") : LS("转入账户"))
                    : c.kind == .expense ? LS("付款账户") : LS("收款账户")
                NavigationLink(value: AccountDest(name: a)) {
                    LabeledContent(label) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(store.displayName(a) ?? D.shortName(a)).foregroundStyle(.primary)
                            if let tail = store.repoConfig?.scanCards?.first(where: { $0.value == a && $0.key.count == 4 && $0.key.allSatisfy(\.isNumber) })?.key {
                                Text(LS("尾号 %@", tail)).font(.caption)
                            }
                        }
                    }
                }
            }
            ForEach(Array(Set(cats)).sorted(), id: \.self) { a in
                NavigationLink(value: AccountDest(name: a)) {
                    LabeledContent(LS("分类"), value: acctDisplay(a))
                }
            }
            LabeledContent(LS("日期"), value: t.date)
            if !t.payee.isEmpty && !t.narration.isEmpty { LabeledContent(LS("备注"), value: t.narration) }
        }
    }

    /// 编辑, 复制, 退款 (退款 for spending only)
    private func actionBar(_ t: Entry, _ L: Ledger, _ D: Derived) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { if await !store.beginEdit(t) { visualUnavailable = true } }
            } label: {
                Label(LS("编辑"), systemImage: "pencil").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.jade)
            Button { again(t, L, D, kind: nil) } label: {
                Label(LS("复制"), systemImage: "doc.on.doc").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            if classify(t, L).kind == .expense {
                Button { refund(t, L, D) } label: {
                    Label(LS("退款"), systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .tint(.jade)
        .fontWeight(.semibold)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    /// everything else: the source, the day's order, subscriptions, copying and opening the text, deleting
    private func moreMenu(_ t: Entry, _ L: Ledger) -> some View {
        Menu {
            if !t.synthetic {
                Button { goSource = true } label: { Label(LS("编辑源文本"), systemImage: "chevron.left.forwardslash.chevron.right") }
                if L.txns.filter({ $0.date == t.date && $0.file == t.file && !$0.synthetic }).count > 1 {
                    Button { ordering = t } label: { Label(LS("调整当天顺序"), systemImage: "arrow.up.arrow.down") }
                }
                if classify(t, L).kind == .expense {
                    if let s = store.subs.first(where: { s in s.charges.contains { $0.txn.id == t.id } }) {
                        Button { subOpen = s.name } label: { Label(LS("订阅：%@", s.name), systemImage: "repeat") }
                    } else {
                        Button { subPick = t } label: { Label(LS("加入订阅管理"), systemImage: "repeat") }
                    }
                }
            }
            Button {
                UIPasteboard.general.string = t.src
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                store.show(LS("已复制到剪贴板"))
            } label: { Label(LS("复制源文本"), systemImage: "doc.on.clipboard") }
            if let u = store.githubURL(t.file, line: t.line) { Link(destination: u) { Label(LS("在网页中打开"), systemImage: "arrow.up.right.square") } }
            if !t.synthetic {
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: { Label(LS("删除交易"), systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(LS("更多"))
    }

    private func again(_ t: Entry, _ L: Ledger, _ D: Derived, kind: DraftKind?) {
        var d = draftFromTxn(t, kind: kind, L, D, defaultFunding: store.defaultFunding)
        d.date = Day.today()
        handOff(d, LS("已载入为新交易，请核对金额与日期"))
    }

    private func refund(_ t: Entry, _ L: Ledger, _ D: Derived) {
        handOff(refundDraft(t, L, D, defaultFunding: store.defaultFunding), LS("已生成退款草稿，请核对金额后保存"))
    }

    /// hand a filled form to 记一笔: close any open detail pages and open the card on it
    private func handOff(_ d: Draft, _ msg: String) {
        store.draft = d
        store.popToken += 1
        store.openAdd()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        store.show(msg)
    }
}

struct PostingRow: View {
    let p: Posting
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text((p.flag.map { $0 + " " } ?? "") + p.account).font(.subheadline).lineLimit(2)
                Spacer()
                if let u = p.units, let c = p.currency {
                    Text(money(u, c, abs(u) < 1 && (p.digits ?? 2) > 2 ? 4 : 2)).monospacedDigit().sensitive()
                }
            }
            if !details.isEmpty {
                Text(details).font(.caption.monospacedDigit()).foregroundStyle(.secondary).sensitive()
            }
            ForEach(p.meta.items, id: \.0) { item in
                Text(item.0 + ": " + item.1.display).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var details: String {
        var parts: [String] = []
        if let pr = p.price, let n = pr.number { parts.append("@ \(fmtNum(n, 4)) \(pr.currency ?? "")") }
        if let c = p.cost, let n = c.number { parts.append("{\(fmtNum(n, 4)) \(c.currency ?? "")\(c.date.map { ", " + $0 } ?? "")}") }
        if p.interpolated { parts.append(LS("自动补平")) }
        return parts.joined(separator: "  ")
    }
}

// MARK: - edit

struct EditTxView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let dest: EditDest
    @State private var old: String?
    @State private var text = ""
    @State private var path = ""
    @State private var summary = ""
    @State private var date = ""
    @State private var confirmDelete = false

    var body: some View {
        Form {
            if let old = old, let L = store.L {
                let aligned = alignText(text)
                let v = validateText(aligned, L, single: true)
                Section {
                    CodeTextView(text: $text, language: .beancount, fontSize: 12.5, fitsContent: true)
                        .frame(minHeight: 200)
                    if v.ok { Label(LS("校验通过"), systemImage: "checkmark.circle").font(.footnote).foregroundStyle(Color.gain) }
                    else if let m = v.msg { Label(m, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(Color.loss) }
                } header: {
                    Text(LS("所在文件：%@。改了日期会移到新日期那一天的最后（跨年时移到那一年的文件）；日期不变则留在原位。", path)).textCase(nil)
                }
                Section {
                    Button { Task { await save(old, L) } } label: { Text(LS("保存修改")).frame(maxWidth: .infinity).fontWeight(.semibold) }
                        .buttonStyle(.borderedProminent).tint(.jade).controlSize(.large)
                        .disabled(!v.ok || aligned.trimmed == old.trimmed)
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
                Section {
                    Button(LS("删除交易"), role: .destructive) { confirmDelete = true }
                }
            } else {
                ProgressView()
            }
        }
        .keyboardDone()
        .navigationTitle(LS("编辑交易"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(LS("删除 %@ %@？", date, summary), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(LS("删除"), role: .destructive) { Task { await delete() } }
        }
        .task { await load() }
    }

    private func load() async {
        guard old == nil, let t = store.txn(dest.id, key: dest.key) else { return }
        path = t.file
        date = t.date
        summary = [t.payee, t.narration].filter { !$0.isEmpty }.joined(separator: " ")
        guard let o = await store.entryText(t) else {
            // the file changed under it: say so instead of spinning forever
            store.show(LS("这笔交易所在的文件已经变了，请刷新后再试"))
            return
        }
        old = o
        text = compactText(o)
    }

    private func save(_ old: String, _ L: Ledger) async {
        // same date, same file: changed where it is, so it keeps its place among that day's entries;
        // a new date moves it to the end of that day (in that year's file)
        guard let ops = await store.replaceOps(old: old, path: path, date: date, summary: summary, newText: alignText(text)) else { return }
        store.popToken += 1
        await store.commit(ops, word: LS("已更新"), checked: true)
    }

    private func delete() async {
        guard let old = old else { return }
        await store.deleteEntry(path: path, old: old, date: date, summary: summary)
    }
}


/// the transactions of one day in one file, dragged into a new order; the file's lines move with them
struct DayOrderSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let date: String
    let file: String
    @State private var items: [Entry] = []
    @State private var original: [Int] = []
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items, id: \.id) { t in TxRow(t: t) }
                        .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text(LS("拖动右侧把手调整 %@ 这一天的先后，保存后 %@ 里这几笔的位置跟着调整，中间的余额断言等内容不动。改到另一天请在「编辑」里改日期。", date, file))
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(LS("调整当天顺序"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LS("保存")) { Task { await save() } }.disabled(items.map { $0.id } == original || saving)
                }
            }
            .onAppear {
                guard items.isEmpty, let L = store.L else { return }
                items = L.txns.filter { $0.date == date && $0.file == file && !$0.synthetic }.sorted { $0.startLine < $1.startLine }
                original = items.map { $0.id }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        guard let text = try? await store.fileText(file) else { store.show(LS("无法读取 %@", file)); return }
        let inFile = items.sorted { $0.startLine < $1.startLine }
        let order = items.compactMap { t in inFile.firstIndex { $0.id == t.id } }
        guard let r = reorderBlocks(text, ranges: inFile.map { ($0.startLine, $0.endLine) }, order: order) else {
            store.show(LS("文件已经变了，请刷新后再试")); return
        }
        var op = Op(kind: .replace, path: file)
        op.old = r.old
        op.text = r.new
        op.date = date
        op.label = LS("调整 %@ 的顺序", date)
        op.summary = op.label
        guard let ops = await store.review([op]) else { return }
        dismiss()
        await store.commit(ops, word: LS("已调整顺序"), checked: true)
    }
}

/// small chips that wrap onto more lines, each with its ✕
struct FlowChips: View {
    let items: [(String, () -> Void)]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                Button(action: it.1) {
                    HStack(spacing: 4) {
                        Text(it.0).lineLimit(1)
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .foregroundStyle(Color.jade)
                    .background(Color.jade.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// lays its children out in rows, wrapping when a row is full
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { y += row + spacing; x = 0; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}
