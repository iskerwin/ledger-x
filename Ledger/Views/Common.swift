import SwiftUI
import LedgerKit

// MARK: - hide amounts

// Amounts are hidden where they are formatted: money() gives "¥***" while 隐藏金额 is on (KitPrivacy).
// The setting is observable, so whatever formatted an amount is redrawn in place when it changes.
// Charts keep their shape but lose the value axis.

struct Sensitive: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if KitPrivacy.masked { content.chartYAxis(.hidden) } else { content }
    }
}

/// a number that is not an amount from money() (units, prices, query cells), hidden the same way
func masked(_ s: String) -> String { KitPrivacy.masked ? "***" : s }

extension View {
    func sensitive() -> some View { modifier(Sensitive()) }
}

struct PrivacyButton: View {
    var body: some View {
        let on = AppSettings.shared.privacy
        Button { AppSettings.shared.privacy.toggle() } label: {
            Image(systemName: on ? "eye.slash" : "eye")
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
    var body: some View {
        Button {
            store.showSync = true
        } label: {
            HStack(spacing: 4) {
                // synced, kept on this phone (waiting or offline), or something to look at
                let problem = store.pending.contains { $0.failed != nil || $0.held != nil }
                switch store.syncState {
                case .syncing: ProgressView().controlSize(.small)
                case .offline: Image(systemName: "icloud.slash").foregroundStyle(.orange)
                case .error: Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                case .idle:
                    if problem { Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange) }
                    else if store.pending.isEmpty { Image(systemName: "checkmark.icloud").foregroundStyle(.secondary) }
                    else { Image(systemName: "icloud.and.arrow.up").foregroundStyle(.orange) }
                }
                let n = store.pending.filter { $0.failed == nil && $0.held == nil }.count
                if n > 0 { Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.orange) }
            }
        }
        .accessibilityLabel(statusText)
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
            HStack(spacing: 14) {
                Text(t.text).font(.subheadline.weight(.medium)).lineLimit(2)
                if let a = t.action {
                    Button(a) {
                        let fn = store.toastAction
                        store.toast = nil
                        if let fn = fn { Task { await fn() } }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.jade)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.bottom, top ? 0 : 64)
            .transition(.move(edge: top ? .top : .bottom).combined(with: .opacity))
            .id(t.id)
            .task(id: t.id) {
                try? await Task.sleep(nanoseconds: UInt64((t.action != nil ? 6 : 2.2) * 1_000_000_000))
                if store.toast?.id == t.id { withAnimation { store.toast = nil } }
            }
        }
    }
}

// MARK: - chips

struct Chip: View {
    let label: String
    var selected = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.jade : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(selected ? Color.onJade : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct ChipRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content }.padding(.vertical, 2)
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
    let pick: (String) -> Void
    @State private var q = ""

    /// accounts grouped by their second level (Food, Bank…), the most used group first; the root
    /// (Expenses, Assets) only shows when two roots share a group name
    private struct Group: Identifiable { let id: String; let title: String; let accounts: [String] }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if allowAny, !q.isEmpty, isAccountName(q), !(store.D?.openAccounts.contains(q) ?? false) {
                        Button { pick(q); dismiss() } label: { Label(LS("使用 %@", q), systemImage: "plus.circle") }
                    }
                    if q.trimmingCharacters(in: .whitespaces).isEmpty {
                        let gs = groups
                        if gs.count > 1 {
                            Section {
                                ChipRow {
                                    ForEach(gs) { g in Chip(label: g.title) { withAnimation { proxy.scrollTo(g.id, anchor: .top) } } }
                                }
                            } header: { Text(LS("分类")) }
                        }
                        let recent = Array(ranked.prefix(5))
                        if ranked.count > 8 {
                            Section(LS("最常用")) { ForEach(recent, id: \.self) { row($0, full: true) } }
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
                        ForEach(results, id: \.self) { row($0, full: true) }
                    }
                }
                .onAppear {
                    // open on the group of the current choice
                    if !current.isEmpty, let g = groups.first(where: { $0.accounts.contains(current) }) {
                        DispatchQueue.main.async { proxy.scrollTo(g.id, anchor: .top) }
                    }
                }
            }
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: LS("搜索账户"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } } }
        }
    }

    /// one account: in a group just what is below the group (Dining, ZABank:Cash) with its Chinese name
    private func row(_ a: String, full: Bool) -> some View {
        Button { pick(a); dismiss() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(full ? acctDisplay(a) : rest(a)).foregroundStyle(.primary)
                    if let n = name(a) { Text(n).font(.caption).foregroundStyle(.secondary) }
                    else if full { Text(a).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if a == current { Image(systemName: "checkmark").foregroundStyle(Color.jade) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private var ranked: [String] { store.D?.rankAccounts(prefixes) ?? [] }

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
        return all.map { ($0, max(fuzzy(t, $0), fuzzy(t, acctDisplay($0)), fuzzy(t, name($0) ?? ""))) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map { $0.0 }
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
        VStack(alignment: .leading, spacing: 8) {
            Button { picking = true } label: {
                HStack {
                    Text(label).foregroundStyle(.secondary)
                    Spacer()
                    Text(value.isEmpty ? LS("选择") : acctDisplay(value))
                        .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
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
        HStack(spacing: 8) {
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

struct KeyboardDone: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(LS("完成")) { hideKeyboard() }.fontWeight(.semibold)
                }
            }
    }
}

extension View {
    /// a 完成 button above the keyboard
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
                .padding(.vertical, 4)
                .padding(.horizontal, theme == .system ? 0 : 8)
        }
        // a chosen theme: its own background, as a code block
        .padding(.vertical, theme == .system ? 0 : 4)
        .background(theme.background.map { Color(uiColor: $0) } ?? .clear, in: RoundedRectangle(cornerRadius: 8))
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
                    HStack {
                        if v.ok { Label(LS("校验通过"), systemImage: "checkmark.circle").foregroundStyle(Color.gain) }
                        else if let m = v.msg, !m.isEmpty { Label(m, systemImage: "xmark.octagon").foregroundStyle(Color.loss) }
                        Spacer()
                    }
                    .font(.footnote)
                    .padding(12)
                    .background(.bar)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDone()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(LS("完成")) { done(alignText(text)); dismiss() }.fontWeight(.semibold) }
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
        VStack(alignment: .leading, spacing: 6) {
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
