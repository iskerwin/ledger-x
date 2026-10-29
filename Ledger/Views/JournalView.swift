import SwiftUI
import LedgerKit

/// points at a transaction by position, and by its text so it survives a re-sync
struct TxDest: Hashable {
    let id: Int
    let key: String
    init(_ t: Entry) { id = t.id; key = TxDest.key(t) }
    static func key(_ t: Entry) -> String { txnKey(t) }
}
struct AccountDest: Hashable { let name: String }

/// one row of a transaction list whose identity is `txnRowID` (the text), not the rebuilt array index
struct TxnListItem: Identifiable {
    let id: String
    let entry: Entry
    static func rows(_ entries: [Entry]) -> [TxnListItem] {
        zip(txnRowIDs(entries), entries).map { TxnListItem(id: $0.0, entry: $0.1) }
    }
}
struct EditDest: Hashable {
    let id: Int
    let key: String
    init(_ t: Entry) { id = t.id; key = TxDest.key(t) }
}

extension Store {
    /// through a table made once per loaded ledger: a detail page asks on every redraw, many times while a change
    /// is saved, and comparing every transaction's text each time stalled it
    func txn(_ id: Int, key: String) -> Entry? {
        guard let L = L else { return nil }
        let lookup: TxnLookup
        if let made = txnLookup, made.ledger === L { lookup = made } else { lookup = TxnLookup(L); txnLookup = lookup }
        return lookup.find(id: id, key: key, moves: movedKeys)
    }

    /// old text → new text of transactions changed in place, so open pages keep showing them
    var movedKeys: [String: String] {
        get { entryMoves[cfg.id] ?? [:] }
        set { entryMoves[cfg.id] = newValue }
    }
    static func normKey(_ k: String) -> String { normEntryText(k) }
    /// Apply the move table computed from the pre-save value snapshot.
    func noteMoved(_ moved: [String: String]) {
        var keys = movedKeys
        keys.merge(moved) { _, new in new }
        movedKeys = keys
    }
}

struct TxRow: View {
    @Environment(Store.self) var store
    let t: Entry
    var account: String? = nil
    var balance: String? = nil
    var showDate = false

    var body: some View {
        if let L = store.L, let D = store.D {
            let c = classify(t, L)
            let cat = t.postings.first { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") }
            HStack(alignment: .top, spacing: AppSpacing.icon) {
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    // who first, then the note; tags only where they fit whole (the first one and +N, else a
                    // count like #2, else none), so a long tag no longer cuts the payee down to two characters
                    let tags = t.tags.filter { $0 != "transfer" && $0 != "fx" }
                    let who = Text(t.payee.isEmpty ? (t.narration.isEmpty ? LS("（无收付款方）") : t.narration) : t.payee).lineLimit(1)
                    let note = (!t.payee.isEmpty && !t.narration.isEmpty) ? t.narration : nil
                    HStack(spacing: AppSpacing.icon) {
                        who.layoutPriority(3)
                        if let note { Text(note).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1) }
                        if t.flag == "!" { Tag(text: LS("待确认"), warn: true).fixedSize().layoutPriority(2) }
                        if t.synthetic { Tag(text: "pad").fixedSize().layoutPriority(2) }
                        if !tags.isEmpty {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: AppSpacing.icon) {
                                    Tag(text: "#" + tags[0]).fixedSize()
                                    if tags.count > 1 { Tag(text: "+\(tags.count - 1)").fixedSize() }
                                }
                                Tag(text: "#\(tags.count)").fixedSize()
                                Color.clear.frame(width: 0, height: 0)
                            }
                            .layoutPriority(2)
                        }
                    }
                    .font(.body)
                    Text((showDate ? t.date + "  " : "") + (cat.map { acctDisplay($0.account) } ?? moneyRoute(t).map { D.shortName($0) }.joined(separator: " → "))
                         + withWhom(t))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: AppSpacing.detail) {
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
            // one line per currency, stacked like the amounts below: side by side, an exchange's two currencies
            // squeezed the payee and broke the amounts across lines
            VStack(alignment: .trailing, spacing: AppSpacing.detail) {
                ForEach(byC.keys.sorted(), id: \.self) { cc in Amount(n: byC[cc]!, c: cc, signed: true, color: true).lineLimit(1) }
            }
        } else if c.kind == .transfer {
            Text(money(c.amount, c.currency ?? "CNY")).monospacedDigit().foregroundStyle(.secondary).sensitive()
        } else {
            // in the transaction's own currency (as on the receipt), not converted; what the account was
            // charged in another currency underneath, for checking against the bank
            let own = sums(t.postings.filter { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") }, negate: true)
            let paid = sums(t.postings.filter { !$0.account.hasPrefix("Expenses:") && !$0.account.hasPrefix("Income:") && !$0.account.hasPrefix("Equity:") }, negate: false)
                .filter { p in !own.contains { $0.0 == p.0 } }
            VStack(alignment: .trailing, spacing: AppSpacing.detail) {
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
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, AppSpacing.icon).padding(.vertical, AppSpacing.detail)
            .background(warn ? Color.warn.opacity(0.18) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: AppRadius.mini))
            .foregroundStyle(warn ? Color.warn : Color.secondary)
            .lineLimit(1)
    }
}

struct JournalView: View {
    @Environment(Store.self) var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path = NavigationPath()
    /// a transaction's page opens out of its row
    @Namespace private var zoom
    /// the search that is applied: set when typing is finished (搜索 on the keyboard), by chips and quick searches
    @State private var q = ""
    /// what is in the search box while typing. Searching every keystroke (and every pinyin letter) redraws the
    /// whole list and its totals, so it only becomes `q` on 搜索, or right away when the box is cleared.
    @State private var typing = ""
    @State private var limit = 150
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var batch: BatchMode?
    /// the month calendar opened above the list, remembered on this device. A plain @State drives it:
    /// an @AppStorage change loses the animation, and the calendar jumped in and out
    @State private var showCalendar = UserDefaults.standard.bool(forKey: Self.calendarKey)
    private static let calendarKey = "ledger.journal.calendar"
    /// a day picked on the calendar: its sheet
    @State private var calendarDay: CalendarDay?
    /// the day sheet's detent: on short screens it starts at a lower fraction, so the first
    /// calendar rows stay above the sheet and remain tappable to switch days
    @State private var dayDetent: PresentationDetent = UIScreen.main.bounds.height < 700 ? .fraction(0.4) : .medium

    private static var dayDetents: Set<PresentationDetent> {
        UIScreen.main.bounds.height < 700 ? [.fraction(0.4), .medium, .large] : [.medium, .large]
    }
    /// a transaction tapped in that sheet, opened once the sheet has gone
    @State private var afterSheet: TxDest?
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
        @MainActor func query(_ store: Store) -> String {
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
                    list(L)
                } else { PageSkeleton(card: false, rows: 10) }
            }
            .refreshable { await store.refresh() }
            .navigationTitle(LS("明细"))
            .toolbar {
                StandardToolbar()
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        withAnimation(reduceMotion ? nil : AppMotion.standard) { showCalendar.toggle() }
                        UserDefaults.standard.set(showCalendar, forKey: Self.calendarKey)
                    } label: {
                        Image(systemName: showCalendar ? "calendar.circle.fill" : "calendar")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(showCalendar ? LS("收起月历") : LS("月历"))
                    Button {
                        withAnimation(AppMotion.standard) { selecting.toggle(); selected = [] }
                    } label: { Label(selecting ? LS("完成") : LS("选择"), systemImage: selecting ? "checkmark" : "checkmark.circle").labelStyle(ControlLabelStyle()) }
                }
            }
            .safeAreaInset(edge: .bottom) { if selecting { batchBar } }
            .sheet(item: $savingFilter) { e in QuickSearchSheet(edit: e) }
            // one sheet for whichever day is picked: switching days changes what it shows instead of
            // presenting a new sheet, which came back at full height
            .sheet(isPresented: Binding(get: { calendarDay != nil }, set: { if !$0 { calendarDay = nil } }), onDismiss: {
                if let t = afterSheet { afterSheet = nil; path.append(t) }
            }) {
                if let d = calendarDay, let L = store.L { daySheet(d.day, L) }
            }
            .sheet(item: $batch) { m in
                BatchEditSheet(entries: selectedEntries, mode: m) { selecting = false; selected = [] }
            }
            .appSearchable(text: $typing, prompt: LS("收付款方、摘要、科目、对方、#标签、金额、2026-09"))
            .searchSuggestions { if typing.isEmpty { searchHelp } }
            .onSubmit(of: .search) { q = typing }
            .onChange(of: typing) { _, text in if text.trimmed.isEmpty && !q.isEmpty { q = "" } }
            .onChange(of: q) { _, applied in if typing != applied { typing = applied } }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationDestination(for: TxDest.self) { TxDetailView(dest: $0).privacyToolbar().zoomed(from: $0, in: zoom) }
            .subscriptionDestinations()
            .navigationDestination(for: EditDest.self) { EditTxView(dest: $0) }
            .navigationDestination(for: AccountDest.self) { RegisterView(account: $0.name).privacyToolbar() }
        }
        // on the stack itself: the pages it opens inherit what is set here, not what is set on its first page
        .pushes(onto: $path)
        .ledgerNavigation("journal", path: $path)
        .ledgerControls("journal", value: Binding(get: {
            var context = BrowseContext()
            context.query = q; context.filters = quick.map(\.rawValue); context.limit = limit
            context.anchor = account
            return context
        }, set: {
            q = $0.query; quick = $0.filters.compactMap(QuickFilter.init(rawValue:)); limit = max(150, $0.limit)
            if account == nil { account = $0.anchor }
        }))
        .onChange(of: store.popToken) { _, _ in path = NavigationPath() }
        .onChange(of: store.journalQuery) { _, new in takeQuery(new) }
        .onChange(of: store.journalJump) { _, jump in applyJump(jump) }
        .task {
            typing = q
            takeQuery(store.journalQuery)
            applyJump(store.journalJump)
            if let q = store.demoEnv["LEDGER_QUERY"] { self.q = q }
            if store.demoEnv["LEDGER_CAL_DAY"] != nil, let L = store.L, let d = search(L).first?.date {
                try? await Task.sleep(nanoseconds: 800_000_000)
                calendarDay = CalendarDay(day: d)
            }
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

    /// the sheet of a day picked on the calendar: its transactions as filtered here, and (with no search on) its
    /// documents
    private func daySheet(_ day: String, _ L: Ledger) -> some View {
        let ts = search(L).filter { $0.date == day }
        let a = account
        let docs = fullQuery.isEmpty ? L.entries.filter { e in
            e.type == .document && e.date == day && (a == nil || e.account.map { $0 == a! || $0.hasPrefix(a! + ":") } ?? false)
        } : []
        return CalendarDaySheet(L: L, day: day, entries: ts, account: a, documents: docs) { t in
            afterSheet = TxDest(t)
            calendarDay = nil
        }
        .presentationDetents(Self.dayDetents, selection: $dayDetent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        // half sheet stays clear of the upper dates, so they stay visible and tappable
        // to switch days; on short screens the sheet starts lower still (see dayDetent).
        // The sheet itself closes by swiping down or with its Done button.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    /// a search handed over from another page (报表 → 查看这 N 笔): it replaces what is on
    private func takeQuery(_ new: String?) {
        guard let x = new else { return }
        q = x; quick = []; account = nil; path = NavigationPath()
        store.journalQuery = nil
    }

    /// the filters, search and account on screen right now
    private func currentBrowse() -> BrowseContext {
        var context = BrowseContext()
        context.query = q
        context.filters = quick.map(\.rawValue)
        context.limit = limit
        context.anchor = account
        return context
    }

    private func show(_ browse: BrowseContext) {
        q = browse.query
        quick = browse.filters.compactMap(QuickFilter.init(rawValue:))
        limit = max(150, browse.limit)
        account = browse.anchor
        path = NavigationPath()
    }

    /// a report or account asked for its transactions. The first request remembers
    /// this page; a later one still goes back to that same page.
    private func applyJump(_ jump: JournalJump?) {
        guard let jump else { return }
        let link = journalLink(jump.kind, from: currentBrowse(), previous: store.journalReturn)
        store.journalReturn = link.previous
        show(link.browse)
        store.journalJump = nil
    }

    private func restoreBrowse() {
        guard let previous = store.journalReturn else { return }
        show(previous)
        store.journalReturn = nil
    }

    private var selectedEntries: [Entry] {
        guard let L = store.L else { return [] }
        return L.txns.filter { !$0.synthetic && selected.contains(TxDest.key($0)) }
    }

    private var batchBar: some View {
        HStack(spacing: AppSpacing.icon) {
            Button {
                if let L = store.L {
                    let keys = search(L).prefix(limit).filter { !$0.synthetic }.map { TxDest.key($0) }
                    selected = selected.count >= keys.count ? [] : Set(keys)
                }
            } label: { Label(LS("全选"), systemImage: "checkmark.circle").labelStyle(ControlLabelStyle()).font(.subheadline) }
            Text(LS("已选 %@ 笔", selected.count)).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(BatchMode.allCases) { m in Button { batch = m } label: { Label(m.name, systemImage: "square.and.pencil") } }
            } label: {
                Label(LS("批量编辑"), systemImage: "square.and.pencil").font(.subheadline.weight(.semibold))
            }
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, AppSpacing.content)
        .padding(.vertical, AppSpacing.control)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, AppSpacing.control)
        .padding(.bottom, AppSpacing.detail)
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
        // just saved from the form and in the list as it is (not filtered out, not past 加载更多): scrolled to, where
        // it lights up; of several with the same text, the top one
        let saved = store.justSaved.flatMap { s -> String? in
            guard let t = shown.first(where: { normEntryText($0.src) == s }) else { return nil }
            return txnRowID(t, among: shown.filter { $0.date == t.date })
        }
        ScrollViewReader { proxy in
            List {
                Section {
                    // the saved searches scroll with the list: pinned under the search box (iOS 26 safeAreaBar), the
                    // large title collapsing moved the bar, which pushed the list back and opened the title again,
                    // over and over
                    if !selecting && !(store.quickSearches.isEmpty && q.trimmed.isEmpty) {
                        QuickSearchBar(q: $q).listRowInsets(EdgeInsets())
                    }
                    // looking by date, the calendar takes the quick filters' place (what is on stays, with its ✕)
                    if showCalendar {
                        JournalCalendar(L: L, entries: matches, account: account, openDay: $calendarDay)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    } else {
                        // the quick filters, then the tags people look for
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: AppSpacing.icon) {
                                ForEach(QuickFilter.allCases) { f in
                                    let on = quick.contains(f)
                                    Button {
                                        // the list changes at once; only the chip's colours fade
                                        if on { quick.removeAll { $0 == f } } else { quick.append(f) }
                                        Haptics.selection()
                                    } label: {
                                        HStack(spacing: AppSpacing.icon) { Image(systemName: f.icon); Text(f.title) }
                                            .font(.subheadline.weight(on ? .semibold : .regular))
                                            .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.icon)
                                            .foregroundStyle(on ? Color.onJade : Color.primary)
                                            .background(on ? Color.jade : Color(.tertiarySystemFill), in: Capsule())
                                            .animation(AppMotion.quick, value: on)
                                    }
                                    .buttonStyle(PressStyle())
                                }
                                ForEach(["#refund", "#transfer", "#fx", "#reimbursed"], id: \.self) { x in
                                    Chip(label: x, selected: q.trimmed == x) { q = q.trimmed == x ? "" : x; Haptics.selection() }
                                }
                            }
                        }
                    }
                    if filtered || store.journalReturn != nil {
                        // what is on, each with its ✕, and 清除 for all of it
                        // beside the conditions when all fit on one line; otherwise on a line of their own under them
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: AppSpacing.control) {
                                FlowChips(items: conditionChips()).fixedSize()
                                Spacer(minLength: 4)
                                filterActions(filtered)
                            }
                            VStack(alignment: .leading, spacing: AppSpacing.icon) {
                                FlowChips(items: conditionChips())
                                HStack(spacing: AppSpacing.control) {
                                    Spacer(minLength: 0)
                                    filterActions(filtered)
                                }
                            }
                        }
                    }
                    if !filtered && !showCalendar {
                        // everything in the ledger, under the filters (a card of its own pushed the first entry down
                        // the screen): say so, so the totals are not read as this month's
                        VStack(alignment: .leading, spacing: AppSpacing.detail) {
                            HStack(spacing: AppSpacing.control) {
                                Text(matches.last.map { LS("全部时间 · %@ 起", $0.date) } ?? LS("全部时间"))
                                Spacer()
                                Text(LS("%@ 笔", matches.count))
                            }
                            HStack(spacing: AppSpacing.control) {
                                if sums.0 != 0 { Text(LS("支出 ") + money(sums.0)).foregroundStyle(Color.loss) }
                                if sums.1 != 0 { Text(LS("收入 ") + money(sums.1)).foregroundStyle(Color.gain) }
                                Spacer()
                            }
                            .monospacedDigit().sensitive()
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if filtered {
                    resultCard(matches, sums)
                }
                ForEach(days, id: \.0) { group in
                    daySection(group.0, group.1, L)
                }
                if matches.count > shown.count {
                    Button { limit += 300 } label: { Label(LS("加载更多（%@ 笔）", min(300, matches.count - shown.count)), systemImage: "chevron.down").labelStyle(ControlLabelStyle()) }.frame(maxWidth: .infinity)
                }
                switch browseEmpty(count: matches.count, filtered: filtered) {
                case .nothingHere:
                    Text(LS("还没有交易")).foregroundStyle(.secondary)
                case .nothingMatches:
                    Text(LS("没有符合筛选的交易")).foregroundStyle(.secondary)
                case .showing:
                    EmptyView()
                }
            }
            .listStyle(.insetGrouped)
            .task(id: saved) {
                guard let saved, !selecting else { return }
                withAnimation(reduceMotion ? nil : AppMotion.standard) { proxy.scrollTo(saved, anchor: .center) }
            }
        }
    }

    /// how to search, while the box is empty: tap an example to start from it
    @ViewBuilder private var searchHelp: some View {
        let month = Day.ym(Day.today()), prev = Day.addMonth(Day.ym(Day.today()), -1)
        let examples: [(String, String)] = [
            ("\(prev) \(month)", LS("两个月份之间（也可写 %@）", prev + "~" + month)),
            ("\(month) 科目:餐饮", LS("这个月、某个科目：几个条件用空格隔开，要同时满足")),
            ("账户:招商 >100", LS("某个账户里大于 100 的（账户名或显示名称都行）")),
            ("payee:滴滴 -加班", LS("收付款方是滴滴，排除摘要里有「加班」的")),
            ("\(Day.today().prefix(4))-Q3", LS("一个季度；也可只写年份 %@", String(Day.today().prefix(4)))),
            ("对方:王五", LS("和某人的往来")),
            ("#trip", LS("带某个标签；^ 开头找链接，! 找待确认")),
            ("#出差|#旅行", LS("用 | 表示任一：带其中一个标签就算；科目:餐饮|交通 也行")),
            ("本月 科目:餐饮", LS("本月、上月、今年、近30天按今天计算；本周和上周跟手机的一周起始日，适合存成快速搜索")),
        ]
        if store.quickSearches.isEmpty {
            Label(LS("搜索后点「保存」，即可加为快速搜索"), systemImage: "bookmark").labelStyle(ControlLabelStyle()).font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(examples, id: \.0) { e in
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
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

    /// 回到刚才的筛选 and 清除, by the conditions
    @ViewBuilder private func filterActions(_ filtered: Bool) -> some View {
        if store.journalReturn != nil {
            Button { restoreBrowse() } label: { Label(LS("回到刚才的筛选"), systemImage: "arrow.uturn.backward").labelStyle(ControlLabelStyle()) }
                .font(.subheadline.weight(.medium)).foregroundStyle(Color.jadeInk).buttonStyle(.plain)
                .accessibilityIdentifier("journal.restore")
        }
        if filtered {
            Button { quick = []; account = nil; q = ""; Haptics.selection() } label: { Label(LS("清除"), systemImage: "xmark.circle").labelStyle(ControlLabelStyle()) }
                .font(.subheadline.weight(.medium)).foregroundStyle(Color.jadeInk).buttonStyle(.plain)
        }
    }

    /// 筛选结果: how many, spent and received, over which days; saved as a quick search from here
    private func resultCard(_ matches: [Entry], _ sums: (Double, Double)) -> some View {
        let first = matches.last?.date, last = matches.first?.date
        let span = TxQuery(fullQuery).dateSpan
        // the range the totals cover: the search's own dates, or all time (with the days actually found)
        let range: String = {
            if let s = span { return s.0 == s.1 ? Day.dayLabel(s.0) : rangeLabel(s.0, s.1) }
            guard let f = first, let l = last else { return LS("全部时间") }
            return LS("全部时间（%@）", f == l ? Day.dayLabel(f) : rangeLabel(f, l))
        }()
        return Section {
            VStack(alignment: .leading, spacing: AppSpacing.icon) {
                HStack(spacing: AppSpacing.control) {
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                        Text(LS("筛选结果 · %@ 笔", matches.count)).font(.headline)
                        Label(range, systemImage: "calendar").labelStyle(ControlLabelStyle()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if account == nil, !fullQuery.isEmpty, !store.quickSearches.contains(where: { $0.query.trimmed == fullQuery }) {
                        Button { savingFilter = QuickSearchEdit(index: nil, name: "", query: fullQuery) } label: { Label(LS("保存为常用筛选"), systemImage: "line.3.horizontal.decrease.circle").labelStyle(ControlLabelStyle()) }
                            .font(.subheadline).foregroundStyle(Color.jadeInk).buttonStyle(.plain)
                    }
                }
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                        Text(LS("支出合计")).font(.caption).foregroundStyle(.secondary)
                        Text(money(sums.0)).font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(Color.loss)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider().frame(height: 36)
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                        Text(LS("收入合计")).font(.caption).foregroundStyle(.secondary)
                        Text(money(sums.1)).font(.title3.weight(.bold).monospacedDigit()).foregroundStyle(Color.gain)
                    }
                    .padding(.leading, AppSpacing.control)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .sensitive()
            }
            .padding(.vertical, AppSpacing.detail)
        }
    }

    /// "10月1日 — 10月31日", with the years when they are not this one or differ
    private func rangeLabel(_ a: String, _ b: String) -> String {
        let years = a.prefix(4) != b.prefix(4) || a.prefix(4) != Day.today().prefix(4)
        func short(_ d: String) -> String {
            let m = String(Int(d.dropFirst(5).prefix(2)) ?? 0), day = String(Int(d.suffix(2)) ?? 0)
            return years ? LS("%@年%@月%@日", String(d.prefix(4)), m, day) : LS("%@月%@日", m, day)
        }
        return short(a) + " — " + short(b)
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
        let (out, inn) = totals(ts, L)
        let year = day.prefix(4) != Day.today().prefix(4) ? " " + day.prefix(4) : ""
        return Section {
            ForEach(TxnListItem.rows(ts)) { row in
                let t = row.entry
                if selecting {
                    let key = TxDest.key(t)
                    Button {
                        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
                    } label: {
                        HStack(spacing: AppSpacing.icon) {
                            Image(systemName: selected.contains(key) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected.contains(key) ? Color.jadeInk : Color.secondary)
                            TxRow(t: t, account: account)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected.contains(key) ? .isSelected : [])
                    .disabled(t.synthetic)
                } else {
                    let just = store.justSaved != nil && store.justSaved == normEntryText(t.src)
                    NavigationLink(value: TxDest(t)) { TxRow(t: t, account: account) }
                        .zoomSource(TxDest(t), in: zoom)
                        .entryActions(t)
                        // just saved from the form: the row lights up for a moment, then settles
                        .listRowBackground(just ? Color.jade.soft : nil)
                        .animation(AppMotion.standard, value: just)
                }
            }
        } header: {
            HStack(spacing: AppSpacing.control) {
                Text(Day.dayLabel(day) + year)
                Spacer()
                DayTotalsText(out: out, inn: inn)
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
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let dest: TxDest
    @State private var subDraft: SubDraft?
    @State private var subPick: Entry?
    @State private var ordering: Entry?
    /// the form can't hold all of this entry: edit its source
    @State private var visualUnavailable = false
    /// the subscription form to open once the picker has gone
    @State private var nextSub: SubDraft?
    @State private var linkPick: LinkPick?
    @State private var linkRemoval: LinkPick?
    @State private var deletion: EntryDeletion?
    /// opens the subscription and the source editor (pages of the tab's own path)
    @Environment(\.push) private var push
    /// a category being changed (the picker open)
    @State private var recategorizing: Recategorize?
    struct Recategorize: Identifiable { let from: String; var id: String { from } }

    /// the postings' categories and accounts, folded away under the summary
    @State private var showPostings = false
    @State private var showSource = false

    var body: some View {
        if let L = store.L, let D = store.D, let t = store.txn(dest.id, key: dest.key) {
            List {
                hero(t, L)
                infoSection(t, L, D)
                // attachment links are shown as the files themselves, in 附件
                let links = t.links.filter { LinkRole.of($0) != .document }
                if !links.isEmpty {
                    // links: open one to see everything it ties together
                    Section(LS("关联记录")) {
                        ForEach(links, id: \.self) { l in
                            let n = (D.byLink[l] ?? []).filter { !$0.synthetic }.count
                            NavigationLink(value: LinkDest(link: l)) {
                                HStack(spacing: AppSpacing.control) {
                                    Label(LinkRole.of(l).title, systemImage: "link").labelStyle(ControlLabelStyle())
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
                        Label(LS("分录详情"), systemImage: "list.bullet.rectangle").labelStyle(ControlLabelStyle())
                    }
                    DisclosureGroup(isExpanded: $showSource) {
                        MonoText(text: t.src)
                        Text("\(t.file):\(t.line)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    } label: {
                        Label(LS("Beancount 源文本"), systemImage: "doc.plaintext").labelStyle(ControlLabelStyle())
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
            .entryDeletion($deletion)
            .navigationTitle(LS("交易详情"))
            .navigationBarTitleDisplayMode(.inline)
            // screenshots: 编辑源文本 through `push`, as the ⋯ menu does
            .task { if store.demoEnv["LEDGER_EDIT_SOURCE"] != nil { try? await Task.sleep(nanoseconds: 700_000_000); editSource() } }
            .sheet(item: $subDraft) { SubEditSheet(draft: $0) }
            .sheet(item: $ordering) { DayOrderSheet(date: $0.date, file: $0.file) }
            .sheet(item: $linkPick) { LinkPickSheet(pick: $0).pickerSheet() }
            .sheet(item: $recategorizing) { r in
                AccountPicker(title: LS("分类"), prefixes: [r.from.hasPrefix("Income:") ? "Income:" : "Expenses:"], current: r.from) { to in
                    guard to != r.from else { return }
                    Task { await store.rewrite([t], label: LS("改分类：%@ → %@", acctLabel(r.from), acctLabel(to))) { accountReplaced(in: $0, from: r.from, to: to) } }
                }
            }
            .linkRemovalDialog($linkRemoval, store: store)
            .alert(LS("这笔请编辑源文本"), isPresented: $visualUnavailable) {
                Button { editSource() } label: { Text(LS("编辑源文本")) }
                Button(role: .cancel) {} label: { Text(LS("取消")) }
            } message: {
                Text(LS("这笔交易有表单表达不了的内容（注释、成本批次、多个价格等），用表单保存会改掉它们，请直接编辑源文本。"))
            }
            .sheet(item: $subPick, onDismiss: {
                if let d = nextSub { nextSub = nil; subDraft = d }
            }) { e in
                SubPickSheet(t: e) { if let L = store.L { nextSub = SubDraft(e, L) } }
            }
        } else if store.L == nil || store.D == nil {
            VStack(spacing: AppSpacing.content) {
                ProgressView()
                Text(LS("正在加载账本…")).foregroundStyle(.secondary)
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
            VStack(spacing: AppSpacing.icon) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(Color.jadeInk)
                    .frame(width: 60, height: 60)
                    .background(Color.jade.soft, in: Circle())
                Text(t.payee.isEmpty ? (t.narration.isEmpty ? LS("交易") : t.narration) : t.payee)
                    .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Group {
                    if c.kind == .transfer {
                        Text(money(c.amount, c.currency ?? L.base))
                    } else {
                        ForEach(own, id: \.0) { x in Text(signedMoney(x.1, x.0)).foregroundStyle(x.1 >= 0 ? Color.gain : Color.loss) }
                    }
                }
                .heroAmount().monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .sensitive()
                if c.kind != .transfer {
                    ForEach(paid, id: \.0) { x in
                        Text(LS("实付 %@", money(x.1, x.0))).font(.footnote.monospacedDigit()).foregroundStyle(.secondary).sensitive()
                    }
                }
                HStack(spacing: AppSpacing.icon) {
                    Text(kindLabel + " · " + t.date)
                    if t.flag == "!" { Tag(text: LS("待确认"), warn: true) }
                }
                .font(.subheadline).foregroundStyle(.secondary)
                if !t.tags.isEmpty {
                    HStack(spacing: AppSpacing.control) { ForEach(t.tags, id: \.self) { Tag(text: "#" + $0) } }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppSpacing.content)
            .padding(.horizontal, AppSpacing.content)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
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
                        VStack(alignment: .trailing, spacing: AppSpacing.detail) {
                            Text(accountTitle(L, a)).foregroundStyle(.primary).lineLimit(1)
                            if let tail = store.repoConfig?.scanCards?.first(where: { $0.value == a && $0.key.count == 4 && $0.key.allSatisfy(\.isNumber) })?.key {
                                Text(LS("尾号 %@", tail)).font(.caption)
                            }
                        }
                    }
                }
            }
            // the category, changed here (only in this transaction); its own register from the long press
            ForEach(Array(Set(cats)).sorted(), id: \.self) { a in
                Button { if !t.synthetic { recategorizing = Recategorize(from: a) } } label: {
                    LabeledContent(LS("分类")) {
                        HStack(spacing: AppSpacing.icon) {
                            Text(acctDisplay(a)).foregroundStyle(.primary).lineLimit(1)
                            if !t.synthetic { Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { push?(AccountDest(name: a)) } label: { Label(LS("查看该分类明细"), systemImage: "list.bullet") }
                }
            }
            if !t.payee.isEmpty && !t.narration.isEmpty { LabeledContent(LS("摘要"), value: t.narration) }
        }
    }

    /// 编辑, 复制, 退款 (退款 for spending only). Same height and width; 编辑 is the filled action.
    private func actionBar(_ t: Entry, _ L: Ledger, _ D: Derived) -> some View {
        var items = [
            ActionRow.Item(title: LS("编辑"), systemImage: "pencil", emphasis: .primary) {
                Task {
                    switch await store.beginEdit(t) {
                    case .opened: break
                    case .needsSource: visualUnavailable = true
                    case .missing: store.show(LS("没有在文件里对上原来的文字，所以没有改动。"))
                    }
                }
            },
            ActionRow.Item(title: LS("复制"), systemImage: "doc.on.doc") {
                again(t, L, D, kind: nil)
            },
        ]
        if classify(t, L).kind == .expense {
            items.append(ActionRow.Item(title: LS("退款"), systemImage: "arrow.uturn.backward") {
                refund(t, L, D)
            })
        }
        return ActionRow(size: .large, items: items)
            .padding(.horizontal, AppSpacing.content)
            .padding(.top, AppSpacing.icon)
            .padding(.bottom, AppSpacing.icon)
            .background(.bar)
    }

    private func editSource() {
        if let t = store.txn(dest.id, key: dest.key) { push?(EditDest(t)) }
    }

    /// everything else: the source, the day's order, subscriptions, copying and opening the text, deleting
    private func moreMenu(_ t: Entry, _ L: Ledger) -> some View {
        Menu {
            if !t.synthetic {
                Button { editSource() } label: { Label(LS("编辑源文本"), systemImage: "chevron.left.forwardslash.chevron.right") }
                if L.txns.filter({ $0.date == t.date && $0.file == t.file && !$0.synthetic }).count > 1 {
                    Button { ordering = t } label: { Label(LS("调整当天顺序"), systemImage: "arrow.up.arrow.down") }
                }
                if classify(t, L).kind == .expense {
                    if let s = store.subs.first(where: { s in s.charges.contains { $0.txn.id == t.id } }) {
                        Button { push?(SubDetailDest(name: s.name)) } label: { Label(LS("订阅：%@", s.name), systemImage: "repeat") }
                    } else {
                        Button { subPick = t } label: { Label(LS("加入订阅管理"), systemImage: "repeat") }
                    }
                }
            }
            Button {
                UIPasteboard.general.string = t.src
                Haptics.success()
                store.show(LS("已复制到剪贴板"))
            } label: { Label(LS("复制源文本"), systemImage: "doc.on.clipboard") }
            if let u = store.githubURL(t.file, line: t.line) { Link(destination: u) { Label(LS("在网页中打开"), systemImage: "arrow.up.right.square") } }
            if !t.synthetic {
                Divider()
                Button(role: .destructive) { deletion = EntryDeletion(t, ledgerID: store.cfg.id, onDeleted: { dismiss() }) } label: { Label(LS("删除交易"), systemImage: "trash") }
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
        store.openAdd()
        Haptics.selection()
        store.show(msg)
    }
}

struct PostingRow: View {
    let p: Posting
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.detail) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.control) {
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
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let dest: EditDest
    @State private var old: String?
    @State private var text = ""
    @State private var path = ""
    @State private var summary = ""
    @State private var date = ""
    @State private var deletion: EntryDeletion?
    @State private var busy = false
    @State private var closeRequested = false
    @State private var ledgerID: String?
    @State private var anchorLine: Int?
    @State private var unmatched = false

    var body: some View {
        Form {
            if unmatched {
                Text(LS("没有在文件里对上原来的文字，所以没有改动。")).foregroundStyle(.secondary)
            } else if let old = old, let L = store.L {
                let aligned = alignText(text)
                let v = validateText(aligned, L, single: true)
                Section {
                    CodeTextView(text: $text, language: .beancount, fontSize: 12.5, fitsContent: true)
                        .frame(minHeight: 200)
                    if v.ok { Label(LS("校验通过"), systemImage: "checkmark.circle").labelStyle(ControlLabelStyle()).font(.footnote).foregroundStyle(Color.gain) }
                    else if let m = v.msg { ValidationRow(message: m) }
                } header: {
                    Text(LS("所在文件：%@。改了日期会移到新日期那一天的最后（跨年时移到那一年的文件）；日期不变则留在原位。", path)).textCase(nil)
                }
                Section {
                    Button { Task { await save(old, L) } } label: { Label(LS("保存修改"), systemImage: "checkmark").labelStyle(ControlLabelStyle()).frame(maxWidth: .infinity).fontWeight(.semibold) }
                        .primaryButton()
                        .disabled(!v.ok || aligned.trimmed == old.trimmed)
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
                Section {
                    Button(role: .destructive) {
                        if let entry = store.txn(dest.id, key: dest.key) { deletion = EntryDeletion(entry, ledgerID: store.cfg.id, onDeleted: { dismiss() }) }
                    } label: { Label(LS("删除交易"), systemImage: "trash").labelStyle(ControlLabelStyle()) }
                }
            } else {
                ProgressView()
            }
        }
        .keyboardDone()
        .navigationTitle(LS("编辑交易"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .navigationBarBackButtonHidden(dirty || busy)
        .toolbar {
            if dirty || busy {
                ToolbarItem(placement: .topBarLeading) {
                    Button { closeRequested = true } label: { Label(LS("返回"), systemImage: "chevron.left").labelStyle(ControlLabelStyle()) }.disabled(busy)
                }
            }
        }
        .protectUnsavedChanges(dirty: dirty, busy: busy, requested: $closeRequested,
            keep: { keepDraft(); dismiss() },
            discard: { if let old = old { store.forgetSourceDraft(file: path, original: old) }; dismiss() },
            close: { dismiss() })
        .entryDeletion($deletion)
        .task { await load() }
        .onChange(of: text) { _, _ in keepDraft() }
        .onChange(of: store.cfg.id) { _, _ in dismiss() }
    }

    private var dirty: Bool { old.map { normEntryText(alignText(text)) != normEntryText(alignText($0)) } ?? false }

    private func keepDraft() {
        guard let old = old, ledgerID == store.cfg.id else { return }
        store.rememberSourceDraft(file: path, original: old, text: text, label: summary)
    }

    private func load() async {
        guard old == nil, let t = store.txn(dest.id, key: dest.key) else { return }
        ledgerID = store.cfg.id
        path = t.file
        date = t.date
        summary = [t.payee, t.narration].filter { !$0.isEmpty }.joined(separator: " ")
        guard let located = await store.locatedSource(t) else {
            unmatched = true
            return
        }
        anchorLine = located.line
        old = located.text
        text = store.sourceDraft(file: path, original: located.text, fallback: compactText(located.text))
    }

    private func save(_ old: String, _ L: Ledger) async {
        guard !busy, ledgerID == store.cfg.id else { return }
        busy = true
        defer { busy = false }
        // same date, same file: changed where it is, so it keeps its place among that day's entries;
        // a new date moves it to the end of that day (in that year's file)
        guard let ops = await store.replaceOps(old: old, path: path, date: date, summary: summary, newText: alignText(text), anchorLine: anchorLine) else { return }
        if await store.commit(ops, word: LS("已更新"), checked: true) {
            guard ledgerID == store.cfg.id else { return }
            store.forgetSourceDraft(file: path, original: old)
            dismiss()
        }
    }


}


/// the transactions of one day in one file, dragged into a new order; the file's lines move with them
struct DayOrderSheet: View {
    @Environment(Store.self) var store
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
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { SaveLabel() }.disabled(items.map { $0.id } == original || saving)
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
        guard let text = try? await store.fileText(file) else { store.showFailure(LS("无法读取 %@", file)); return }
        let inFile = items.sorted { $0.startLine < $1.startLine }
        let order = items.compactMap { t in inFile.firstIndex { $0.id == t.id } }
        guard let r = reorderBlocks(text, ranges: inFile.map { ($0.startLine, $0.endLine) }, order: order) else {
            store.show(LS("文件已经变了，请刷新后再试")); return
        }
        var op = Op(kind: .replace, path: file)
        op.old = r.old
        op.text = r.new
        op.date = date
        op.anchorLine = inFile.first.map { $0.startLine + 1 }
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
        FlowLayout(spacing: AppSpacing.icon) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                Button(action: it.1) {
                    HStack(spacing: AppSpacing.detail) {
                        Text(it.0).lineLimit(1)
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, AppSpacing.icon).padding(.vertical, AppSpacing.icon)
                    .foregroundStyle(Color.jadeInk)
                    .background(Color.jade.soft, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// lays its children out in rows, wrapping when a row is full
struct FlowLayout: Layout {
    var spacing: CGFloat = AppSpacing.icon
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = size(v, width)
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
            let s = size(v, bounds.width)
            if x > bounds.minX && x + s.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }

    /// a child at its own width, but never wider than a row: a long one is cut short instead of drawn over its
    /// neighbours
    private func size(_ v: LayoutSubview, _ width: CGFloat) -> CGSize {
        let s = v.sizeThatFits(.unspecified)
        guard s.width > width, width.isFinite else { return s }
        return v.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}
