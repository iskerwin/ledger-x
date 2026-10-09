import SwiftUI
import LedgerKit

// MARK: - hide amounts

struct Sensitive: ViewModifier {
    @AppStorage("ledger.privacy") private var privacy = false
    func body(content: Content) -> some View {
        content.blur(radius: privacy ? 7 : 0).animation(.easeInOut(duration: 0.2), value: privacy)
    }
}

extension View {
    func sensitive() -> some View { modifier(Sensitive()) }
}

struct PrivacyButton: View {
    @AppStorage("ledger.privacy") private var privacy = false
    var body: some View {
        Button { privacy.toggle() } label: {
            Image(systemName: privacy ? "eye.slash" : "eye")
        }
        .accessibilityLabel(privacy ? LS("显示金额") : LS("隐藏金额"))
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
            Task { await store.syncNow() }
        } label: {
            HStack(spacing: 4) {
                switch store.syncState {
                case .syncing: ProgressView().controlSize(.small)
                case .offline: Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .idle: Image(systemName: store.pending.isEmpty ? "checkmark.icloud" : "icloud.and.arrow.up").foregroundStyle(store.pending.isEmpty ? Color.secondary : Color.orange)
                }
                let n = store.pending.filter { $0.failed == nil }.count
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
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            PrivacyButton()
            SyncBadge()
            SettingsButton()
        }
    }
}

// MARK: - toast

struct ToastView: View {
    @EnvironmentObject var store: Store
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
            .padding(.bottom, 64)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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

    var body: some View {
        NavigationStack {
            List {
                if allowAny, !q.isEmpty, isAccountName(q), !(store.D?.openAccounts.contains(q) ?? false) {
                    Button { pick(q); dismiss() } label: { Label(LS("使用 %@", q), systemImage: "plus.circle") }
                }
                ForEach(results, id: \.self) { a in
                    Button { pick(a); dismiss() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(acctDisplay(a)).foregroundStyle(.primary)
                                Text(a).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if a == current { Image(systemName: "checkmark").foregroundStyle(Color.jade) }
                        }
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

    var results: [String] {
        guard let D = store.D else { return [] }
        let all = D.rankAccounts(prefixes)
        let t = q.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return all }
        return all.map { ($0, max(fuzzy(t, $0), fuzzy(t, acctDisplay($0)))) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map { $0.0 }
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
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: compactText(text))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 4)
        }
        .sensitive()
    }
}


/// full-screen editor for Beancount text; shows it compact and re-aligns on done
struct TextEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initial: String
    var validate: (String) -> Validation? = { _ in nil }
    let done: (String) -> Void
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 8)
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
