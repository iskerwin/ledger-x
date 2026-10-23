import SwiftUI
import LedgerKit

// MARK: - opening pages

// A page is opened by appending a value to its tab's navigation path (NavigationStack(path:)). A page that needs
// to open another one from a button (not a NavigationLink, which takes a whole list row or card) uses `push`, so
// it never declares a destination of its own: SwiftUI pushes pages over and over when `navigationDestination(item:
// / isPresented:)` on a pushed page is mixed with the path's values.

private struct PushKey: EnvironmentKey { static let defaultValue: ((any Hashable) -> Void)? = nil }

extension EnvironmentValues {
    /// append a value to the current tab's navigation path (nil outside a tab's stack)
    var push: ((any Hashable) -> Void)? {
        get { self[PushKey.self] }
        set { self[PushKey.self] = newValue }
    }
}

extension View {
    /// let the pages in this stack open others through `push`; set on the NavigationStack itself (pages it opens
    /// inherit the stack's environment, not that of its first page)
    func pushes(onto path: Binding<NavigationPath>) -> some View {
        environment(\.push, { path.wrappedValue.append($0) })
    }
}

// MARK: - hide amounts

// Amounts are hidden where they are formatted: money() gives "¥***" while 隐藏金额 is on (KitPrivacy).
// The setting is observable, so whatever formatted an amount is redrawn in place when it changes.
// Charts keep their shape but lose the value axis.

struct Sensitive: ViewModifier {
    var xAxis = false
    @ViewBuilder
    func body(content: Content) -> some View {
        if KitPrivacy.masked {
            let hidden = content.chartYAxis(.hidden)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(LS("金额已隐藏"))
                .accessibilityValue("")
                .accessibilityHint("")
            if xAxis { hidden.chartXAxis(.hidden) } else { hidden }
        } else { content }
    }
}

/// a number that is not an amount from money() (units, prices, query cells), hidden the same way
func masked(_ s: String) -> String { KitPrivacy.masked ? "***" : s }

extension View {
    func sensitive(xAxis: Bool = false) -> some View { modifier(Sensitive(xAxis: xAxis)) }
}

struct PrivacyButton: View {
    var body: some View {
        let on = AppSettings.shared.privacy
        Button { AppSettings.shared.privacy.toggle() } label: {
            Image(systemName: on ? "eye.slash" : "eye")
                .contentTransition(.symbolEffect(.replace))
                .animation(AppMotion.quick, value: on)
        }
        .accessibilityLabel(on ? LS("显示金额") : LS("隐藏金额"))
    }
}

extension View {
    /// the show / hide amounts button on a pushed page (the root pages have it in their toolbar)
    /// `currency`: also the 币种与换算 button (pages that follow it)
    func privacyToolbar(currency: Bool = false) -> some View {
        toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if currency { CurrencyButton() }
                PrivacyButton()
            }
        }
    }
}

struct Amount: View {
    let n: Double
    var c = "CNY"
    var d = 2
    var signed = false
    var color = false
    var body: some View {
        Text(signed ? signedMoney(n, c) : money(n, c, d))
            .monospacedDigit()
            .foregroundStyle(color ? (n > 1e-9 ? Color.gain : n < -1e-9 ? Color.primary : Color.secondary) : Color.primary)
            .sensitive()
    }
}

// MARK: - sync status in the nav bar

struct SyncBadge: View {
    @EnvironmentObject var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button {
            store.showSync = true
        } label: {
            HStack(spacing: AppSpacing.detail) {
                // synced, kept on this phone (waiting or offline), or something to look at
                let problem = store.pending.contains { $0.failed != nil || $0.held != nil }
                // one icon whose symbol changes in place (the system's replace transition), turning while it syncs
                // (iOS 18; a spinner before that)
                let state: (symbol: String, color: Color) = {
                    switch store.syncState {
                    case .syncing: return ("arrow.triangle.2.circlepath.icloud", .secondary)
                    case .offline: return ("icloud.slash", Color.warn)
                    case .error: return ("exclamationmark.icloud", Color.warn)
                    case .idle:
                        if problem { return ("exclamationmark.icloud", Color.warn) }
                        return store.pending.isEmpty ? ("checkmark.icloud", .secondary) : ("icloud.and.arrow.up", Color.warn)
                    }
                }()
                if store.syncState == .syncing, #unavailable(iOS 18.0) {
                    ProgressView().controlSize(.small)
                } else {
                    syncIcon(state.symbol, syncing: store.syncState == .syncing)
                        .foregroundStyle(state.color)
                        .contentTransition(.symbolEffect(.replace))
                        // a sync that didn't go through gives one bounce, to be noticed
                        .symbolEffect(.bounce, value: reduceMotion ? false : state.symbol == "exclamationmark.icloud")
                        .animation(AppMotion.quick, value: state.symbol)
                }
                let n = store.pending.filter { $0.failed == nil && $0.held == nil }.count
                if n > 0 { Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(Color.warn).rollingNumber(n, AppMotion.quick) }
            }
        }
        .accessibilityLabel(statusText)
    }
    @ViewBuilder
    private func syncIcon(_ symbol: String, syncing: Bool) -> some View {
        if #available(iOS 18.0, *) {
            Image(systemName: symbol).symbolEffect(.rotate, isActive: syncing)
        } else {
            Image(systemName: symbol)
        }
    }

    var statusText: String {
        switch store.syncState {
        case .syncing: return LS("同步中")
        case .offline: return LS("离线")
        case .error: return LS("同步出错：%@", store.syncError)
        case .idle: return store.pending.isEmpty ? LS("已同步") : LS("%@ 项待同步", store.pending.count)
        }
    }
}

struct SettingsButton: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Button { store.showSettings = true } label: { Image(systemName: "gearshape") }
            .accessibilityLabel(LS("设置"))
    }
}

struct StandardToolbar: ToolbarContent {
    /// the page follows 币种与换算 (overview, accounts)
    var currency = false
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if currency { CurrencyButton() }
            PrivacyButton()
            SyncBadge()
            SettingsButton()
        }
    }
}

// MARK: - toast

struct ToastView: View {
    @EnvironmentObject var store: Store
    /// at the top of a card whose bottom is taken by a keypad
    var top = false
    var body: some View {
        if let t = store.toast {
            HStack(spacing: AppSpacing.control) {
                if t.success { SavedCheck() }
                Text(t.text).font(.subheadline.weight(.medium)).lineLimit(2)
                    .accessibilityIdentifier("toast.message")
                if let a = t.action {
                    Button {
                        store.performToastAction()
                    } label: { Label(a, systemImage: "arrow.uturn.backward").labelStyle(ControlLabelStyle()) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.jade)
                }
            }
            .padding(.horizontal, AppSpacing.content).padding(.vertical, AppSpacing.control)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.bottom, top ? 0 : 64)
            .transition(.move(edge: top ? .top : .bottom).combined(with: .opacity))
            .id(t.id)
        }
    }
}

/// the check in front of a saved notice: it pops in once (no pop under 减少动态效果)
private struct SavedCheck: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.jade)
            .symbolEffect(.bounce, value: shown)
            .onAppear { if !reduceMotion { shown = true } }
            .accessibilityHidden(true)
            .accessibilityIdentifier("toast.saved")
    }
}

// MARK: - chips

struct Chip: View {
    let label: String
    /// A real symbol for this chip. Empty means text only; selection is the green fill, not a checkmark.
    var systemImage: String? = nil
    var selected = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            chipLabel
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.icon)
                .background(selected ? Color.jade : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(selected ? Color.onJade : Color.primary)
                .animation(AppMotion.quick, value: selected)
        }
        .buttonStyle(PressStyle())
    }

    @ViewBuilder private var chipLabel: some View {
        if let systemImage {
            Label(label, systemImage: systemImage).labelStyle(ControlLabelStyle())
        } else {
            Text(label)
        }
    }
}

/// An empty list that is for adding things to (budgets, people, events, subscriptions): what goes here, and a
/// button that adds the first one, the same as + in the bar
struct EmptyAdd: View {
    let text: String
    let title: String
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.control) {
            Text(text).foregroundStyle(.secondary)
            Button(action: add) { Label(title, systemImage: "plus.circle").labelStyle(ControlLabelStyle()) }
                .buttonStyle(.borderless).fontWeight(.semibold).tint(Color.jade)
                .accessibilityIdentifier("empty.add")
        }
        .padding(.vertical, AppSpacing.detail)
    }
}

/// Symbol and colour of one account. Expense and income accounts use their own icon, unless that
/// guess is the generic grid, in which case the group icon is used. Everything else uses the group icon.
/// Store's icon lookup is main-actor-only, and this is only called from views.
@MainActor
func accountMark(_ store: Store, _ account: String) -> (symbol: String, color: Color) {
    let k = store.groupIcon(account)
    if account.hasPrefix("Expenses:") || account.hasPrefix("Income:") {
        let own = store.catIcon(account)
        return (own == "square.grid.2x2" ? k.symbol : own, k.color)
    }
    return (k.symbol, k.color)
}

/// The chosen account's icon. An empty choice keeps the plain column glyph.
struct ChosenAccountIcon: View {
    @EnvironmentObject private var store: Store
    var account: String

    var body: some View {
        let empty = account.trimmingCharacters(in: .whitespaces).isEmpty
        let mark = accountMark(store, account)
        Image(systemName: empty ? "building.columns" : mark.symbol)
            .foregroundStyle(empty ? Color.secondary : mark.color)
    }
}

struct ChipRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.icon) { content }.padding(.vertical, AppSpacing.detail)
        }
    }
}

// MARK: - account picker

struct AccountPicker: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let title: String
    let prefixes: [String]
    var current: String = ""
    var allowAny = false
    /// a word beside some accounts ("同账户换汇" beside the account a transfer goes out of)
    var hints: [String: String] = [:]
    let pick: (String) -> Void
    @State private var q = ""
    @FocusState private var searchFocused: Bool
    @State private var pending: String?
    @State private var detent = PresentationDetent.medium
    /// a group to scroll to once the search is cleared
    @State private var jump: String?
    @State private var order: [String]?
    @State private var recentOrder: [String] = []
    private var selected: String { pending ?? current }

    /// accounts grouped by their second level (Food, Bank…), the most used group first; the root
    /// (Expenses, Assets) only shows when two roots share a group name
    private struct Group: Identifiable { let id: String; let title: String; let accounts: [String] }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if allowAny, !q.isEmpty, isAccountName(q), !(store.D?.openAccounts.contains(q) ?? false) {
                        Button { pending = q.trimmed; searchFocused = false; hideKeyboard(); Haptics.selection() } label: { Label(LS("使用 %@", q), systemImage: "plus.circle").labelStyle(ControlLabelStyle()) }
                    }
                    if q.trimmingCharacters(in: .whitespaces).isEmpty {
                        let gs = groups
                        // the one chosen is in the bar above the list: these are the others to switch to
                        let recent = recentOrder.filter { $0 != selected }
                        if !recent.isEmpty {
                            Section(LS("最近使用")) { ForEach(recent, id: \.self) { row($0, full: true) } }
                        }
                        if ranked.count > 8 {
                            Section(LS("最常用")) { ForEach(Array(ranked.filter { $0 != selected }.prefix(5)), id: \.self) { row($0, full: true) } }
                        }
                        ForEach(gs) { g in
                            Section {
                                ForEach(g.accounts, id: \.self) { row($0, full: false) }
                            } header: {
                                Text(g.title).textCase(nil)
                            }
                            .id(g.id)
                        }
                    } else {
                        if results.isEmpty { ContentUnavailableView.search(text: q) }
                        ForEach(results, id: \.self) { row($0, full: true) }
                    }
                }
                .onAppear {
                    if order == nil {
                        order = store.D?.rankAccounts(prefixes) ?? []
                        recentOrder = recentAccounts()
                    }
                    // opens at the top, on the recent and most used: whoever opens it again wants another account
                }
                // a group picked while searching: the search is cleared first, and the jump made once the
                // groups are back in the list
                .task(id: jump) {
                    guard let g = jump else { return }
                    await Task.yield()
                    withAnimation(AppMotion.standard) { proxy.scrollTo(g, anchor: .top) }
                    jump = nil
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        HStack(spacing: AppSpacing.icon) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField(LS("搜索账户"), text: $q)
                                .textFieldStyle(.plain)
                                .focused($searchFocused)
                                .submitLabel(.search)
                                .onSubmit { searchFocused = false }
                                .accessibilityIdentifier("account.search")
                            if !q.isEmpty {
                                Button { q = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .accessibilityLabel(LS("清除搜索"))
                            }
                        }
                        .padding(AppSpacing.icon)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, AppSpacing.content).padding(.top, AppSpacing.icon)
                        shortcuts(proxy)
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGroupedBackground))
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(pending != nil && pending != current)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) }.accessibilityIdentifier("account.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { pick(selected); Haptics.selection(); dismiss() } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }
                        .fontWeight(.semibold).disabled(selected.isEmpty)
                        .accessibilityIdentifier("account.done")
                }
            }
        }
        .pickerSheet($detent)
        .onChange(of: searchFocused) { _, typing in if typing { detent = .large } }
    }

    /// under the search, always in sight: the account chosen, then the groups to jump to
    @ViewBuilder
    private func shortcuts(_ proxy: ScrollViewProxy) -> some View {
        let gs = groups
        if !selected.isEmpty || gs.count > 1 {
            ChipRow {
                if !selected.isEmpty {
                    chosen(proxy, gs)
                    if gs.count > 1 { Divider().frame(height: 20) }
                }
                if gs.count > 1 {
                    ForEach(gs) { g in
                        Chip(label: g.title, systemImage: store.groupIcon(g.id).symbol) { go(g.id, proxy) }
                            .accessibilityIdentifier("account.group." + g.id)
                    }
                }
            }
            .contentMargins(.horizontal, AppSpacing.content, for: .scrollContent)
            .padding(.vertical, AppSpacing.detail)
        }
    }

    /// the account chosen, as a selected chip; a tap goes to its group
    private func chosen(_ proxy: ScrollViewProxy, _ gs: [Group]) -> some View {
        let mark = accountMark(store, selected)
        return Button { if let g = gs.first(where: { $0.accounts.contains(selected) }) { go(g.id, proxy) } } label: {
            HStack(spacing: AppSpacing.icon) {
                ControlIcon(systemName: mark.symbol)
                Text(acctDisplay(selected)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "checkmark").font(.caption.weight(.bold))
            }
            .font(.subheadline)
            .frame(maxWidth: 240)
            .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.icon)
            .background(Color.jade, in: Capsule())
            .foregroundStyle(Color.onJade)
            .animation(AppMotion.quick, value: selected)
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(LS("已选择") + " " + acctDisplay(selected))
        .accessibilityIdentifier("account.chosen")
    }

    /// to a group: at once, or after clearing the search that hides the groups
    private func go(_ group: String, _ proxy: ScrollViewProxy) {
        if q.trimmingCharacters(in: .whitespaces).isEmpty {
            withAnimation(AppMotion.standard) { proxy.scrollTo(group, anchor: .top) }
        } else {
            q = ""
            searchFocused = false
            jump = group
        }
    }

    /// one account: in a group just what is below the group (Dining, ZABank:Cash) with its Chinese name
    private func row(_ a: String, full: Bool) -> some View {
        let mark = accountMark(store, a)
        return Button { pending = a; searchFocused = false; hideKeyboard(); Haptics.selection() } label: {
            HStack(spacing: AppSpacing.icon) {
                ControlIcon(systemName: mark.symbol).foregroundStyle(mark.color)
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    Text(full ? acctDisplay(a) : rest(a)).foregroundStyle(.primary)
                    if let n = name(a) { Text(n).font(.caption).foregroundStyle(.secondary) }
                    else if full { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer()
                if let h = hints[a] { Text(h).font(.caption).foregroundStyle(.secondary) }
                if a == selected { Image(systemName: "checkmark").foregroundStyle(Color.jade) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("account." + a)
        .accessibilityAddTraits(a == selected ? .isSelected : [])
    }

    /// below the group: Expenses:Food:Dining → Dining, Assets:Bank:ZABank:Cash → ZABank:Cash
    private func rest(_ a: String) -> String {
        let p = a.components(separatedBy: ":")
        return p.count > 2 ? p.dropFirst(2).joined(separator: ":") : acctLabel(a)
    }

    /// the account's own name (name: in the ledger), when it says more than the account does
    private func name(_ a: String) -> String? {
        guard let L = store.L, let n = metaName(L, a), n != leaf(a) else { return nil }
        return n
    }

    private var ranked: [String] { order ?? store.D?.rankAccounts(prefixes) ?? [] }

    private func recentAccounts() -> [String] {
        let allowed = Set(ranked)
        var seen = Set<String>(), result: [String] = []
        for transaction in (store.L?.txns ?? []).reversed() {
            for posting in transaction.postings where allowed.contains(posting.account) && seen.insert(posting.account).inserted {
                result.append(posting.account)
                if result.count == 5 { return result }
            }
        }
        return result
    }

    private var groups: [Group] {
        var order: [String] = [], members: [String: [String]] = [:]
        for a in ranked {
            let p = a.components(separatedBy: ":")
            let key = p.count > 1 ? p[0] + ":" + p[1] : a
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(a)
        }
        // a group name used under two roots (Expenses:Gifts, Income:Gifts) keeps its root
        var count: [String: Int] = [:]
        for k in order { count[k.components(separatedBy: ":").last ?? k, default: 0] += 1 }
        return order.map { k in
            let p = k.components(separatedBy: ":")
            let g = p.last ?? k
            let zh = p.count > 1 ? (acctZH(k + ":x").map { " · " + $0 } ?? "") : ""
            let title = ((count[g] ?? 0) > 1 ? k : g) + zh
            return Group(id: k, title: title, accounts: members[k]!)
        }
    }

    var results: [String] {
        let all = ranked
        let t = q.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return all }
        var scored: [(account: String, score: Int, index: Int)] = []
        for (index, account) in all.enumerated() {
            let rawScore = fuzzy(t, account)
            let displayScore = fuzzy(t, acctDisplay(account))
            let nameScore = fuzzy(t, name(account) ?? "")
            let score = max(rawScore, displayScore, nameScore)
            if score > 0 { scored.append((account, score, index)) }
        }
        scored.sort { left, right in
            if left.score == right.score { return left.index < right.index }
            return left.score > right.score
        }
        return scored.map { $0.account }
    }
}

func fuzzy(_ q: String, _ s: String) -> Int {
    let q = q.lowercased(), s = s.lowercased()
    if s.contains(q) { return 2 }
    var it = q.makeIterator()
    var c = it.next()
    for ch in s where ch == c { c = it.next() }
    return c == nil ? 1 : 0
}

/// a row that shows the chosen account and the most-used ones as chips
struct AccountField: View {
    @EnvironmentObject var store: Store
    let label: String
    let prefixes: [String]
    let chips: [String]
    @Binding var value: String
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.icon) {
            Button { picking = true } label: {
                HStack(spacing: AppSpacing.control) {
                    Text(label).foregroundStyle(.secondary)
                    Spacer()
                    Text(value.isEmpty ? LS("选择") : acctDisplay(value))
                        .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("field." + label)
            .accessibilityValue(value)
            if !chips.isEmpty {
                ChipRow {
                    ForEach(chips, id: \.self) { a in
                        Chip(label: acctDisplay(a), selected: a == value) { value = a }
                    }
                }
            }
        }
        .sheet(isPresented: $picking) {
            AccountPicker(title: label, prefixes: prefixes, current: value) { value = $0 }
        }
    }
}

// MARK: - date field

struct DateField: View {
    @Binding var value: String
    var body: some View {
        HStack(spacing: AppSpacing.icon) {
            DatePicker(LS("日期"), selection: Binding(get: { Day.date(value) ?? Date() }, set: { value = Day.string($0) }), displayedComponents: .date)
                .labelsHidden()
            Spacer(minLength: 0)
            ForEach(0..<2, id: \.self) { k in
                let d = Day.shift(Day.today(), -k)
                Chip(label: k == 0 ? LS("今天") : LS("昨天"), selected: value == d) { value = d }
                    .fixedSize()
            }
        }
    }
}

// MARK: - keyboard

/// closes the keyboard whatever field has it (TextField, TextEditor, search)
@MainActor func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// The one button above the keyboard that puts it away. Called 收起键盘, not 完成, so it is never mistaken for a
/// sheet's own 完成 (by eye, by VoiceOver or by a test).
struct HideKeyboardButton: View {
    var action: () -> Void = {}
    var body: some View {
        Button { action(); hideKeyboard() } label: {
            Label(LS("收起键盘"), systemImage: "keyboard.chevron.compact.down").labelStyle(ControlLabelStyle())
        }
        .fontWeight(.semibold)
    }
}

struct KeyboardDone: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    HideKeyboardButton()
                }
            }
    }
}

extension View {
    /// 收起键盘 above the keyboard (the only way this app writes it)
    func keyboardDone() -> some View { modifier(KeyboardDone()) }
}

// MARK: - text helpers

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// narrow screens: collapse the alignment padding before amounts (display only)
func compactText(_ t: String) -> String {
    t.replacingOccurrences(of: #" {3,}(?=-?\d)"#, with: "  ", options: .regularExpression)
}

struct MonoText: View {
    let text: String
    var body: some View {
        let theme = CodeTheme.current
        ScrollView(.horizontal, showsIndicators: false) {
            Text(highlighted(compactText(text), .beancount, theme: theme))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, AppSpacing.detail)
                .padding(.horizontal, theme == .system ? 0 : 8)
        }
        // a chosen theme: its own background, as a code block
        .padding(.vertical, theme == .system ? 0 : 4)
        .background(theme.background.map { Color(uiColor: $0) } ?? .clear, in: RoundedRectangle(cornerRadius: AppRadius.tile))
        .environment(\.colorScheme, theme.forcesDark ? .dark : colorScheme)
        .sensitive()
    }
    @Environment(\.colorScheme) private var colorScheme
}


/// full-screen editor for Beancount text; shows it compact and re-aligns on done
struct TextEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initial: String
    var validate: (String) -> Validation? = { _ in nil }
    let done: (String) -> Void
    @State private var text = ""
    @State private var focused = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CodeTextView(text: $text, language: .beancount, focused: $focused)
                if let v = validate(text) {
                    HStack(spacing: AppSpacing.control) {
                        if v.ok { Label(LS("校验通过"), systemImage: "checkmark.circle").labelStyle(ControlLabelStyle()).foregroundStyle(Color.gain) }
                        else if let m = v.msg, !m.isEmpty { Label(m, systemImage: "xmark.octagon").labelStyle(ControlLabelStyle()).foregroundStyle(Color.loss) }
                        Spacer()
                    }
                    .font(.footnote)
                    .padding(AppSpacing.control)
                    .background(.bar)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDone()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) { Button { done(alignText(text)); dismiss() } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }.fontWeight(.semibold) }
            }
            .onAppear { text = compactText(initial) }
        }
    }
}

/// who a personal receivable posting is with (person:): typed, or one of the people in 往来
struct PersonField: View {
    @EnvironmentObject var store: Store
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.icon) {
            LabeledContent(LS("对方")) {
                TextField(LS("称呼，如 五姨"), text: $value).multilineTextAlignment(.trailing)
            }
            let ps = store.L.map { L in Array(people(L).filter { !$0.closed && !$0.unnamed }.prefix(8)) } ?? []
            if !ps.isEmpty {
                ChipRow { ForEach(ps) { p in Chip(label: p.name, selected: value == p.name) { value = p.name } } }
            }
            if value.trimmed.isEmpty {
                Text(LS("个人往来的每一笔都要写明是谁")).font(.caption).foregroundStyle(Color.warn)
            }
        }
    }
}

extension View {
    /// a row under the navigation bar that the list scrolls beneath: on iOS 26 it shares the bar's soft edge
    /// (no background of its own); before that a bar material of its own height
    @ViewBuilder func topBar<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .top, spacing: 0) { content().background(.bar, ignoresSafeAreaEdges: []) }
        }
    }
}
