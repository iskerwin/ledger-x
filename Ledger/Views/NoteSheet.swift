import SwiftUI
import LedgerKit

/// a note to add (nil) or edit
struct NoteEdit: Identifiable {
    let id = UUID()
    var note: Entry?
}

/// a `note` directive in an account's register
struct NoteRow: View {
    let note: Entry
    /// the account whose register it is in (a note on a subaccount names it)
    let account: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.bubble").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.comment ?? "").font(.subheadline)
                let sub = note.account.flatMap { $0 == account ? nil : acctDisplay($0) }
                Text([note.date, sub].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

/// add or edit a note on an account: `2026-10-16 note Assets:Bank:CGB "…"`
struct NoteSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let account: String
    let note: Entry?
    @State private var date = Day.today()
    @State private var text = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(LS("如：致电银行，额度已调整"), text: $text, axis: .vertical)
                        .lineLimit(2...6)
                        .focused($focused)
                    DatePicker(LS("日期"), selection: Binding(get: { Day.date(date) ?? Date() }, set: { date = Day.string($0) }), displayedComponents: .date)
                } footer: {
                    Text(LS("写入账本：%@", noteText(date: date, account: note?.account ?? account, comment: text.isEmpty ? "…" : text)))
                        .font(.caption.monospaced())
                }
                if let n = note {
                    Section {
                        Button(role: .destructive) {
                            busy = true
                            Task {
                                if await store.deleteDirective(n, summary: LS("备注")) { dismiss() }
                                busy = false
                            }
                        } label: {
                            HStack(spacing: 6) { Spacer(minLength: 0); Image(systemName: "trash"); Text(LS("删除备注")); Spacer(minLength: 0) }
                        }
                    }
                }
            }
            .keyboardDone()
            .navigationTitle(note == nil ? LS("添加备注") : LS("编辑备注"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LS("保存")) { save() }.disabled(text.trimmed.isEmpty || busy)
                }
            }
            .onAppear {
                if let n = note { date = n.date; text = n.comment ?? "" } else { focused = true }
            }
        }
    }

    private func save() {
        busy = true
        Task {
            let ok: Bool
            if let n = note {
                ok = await store.replaceDirective(n, with: noteText(date: date, account: n.account ?? account, comment: text),
                                                  summary: LS("备注"), word: LS("已更新备注"))
            } else {
                ok = await store.addNote(account: account, date: date, comment: text)
            }
            busy = false
            if ok { dismiss() }
        }
    }
}

/// record a new value of one of Beancount's events (where you live, who you work for…)
struct LifeEventSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    /// the type to start with (nil: choose or name one)
    let type: String?
    @State private var kind = ""
    @State private var value = ""
    @State private var date = Day.today()
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                let types = store.L.map { lifeEvents($0).map { $0.type } } ?? []
                Section {
                    TextField(LS("类型，如 location、employer"), text: $kind)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !types.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(types, id: \.self) { t in Chip(label: t, selected: kind == t) { kind = t } } }
                        }
                    }
                } header: {
                    Text(LS("类型"))
                }
                Section {
                    TextField(LS("新的值，如 深圳"), text: $value)
                    DatePicker(LS("从哪天起"), selection: Binding(get: { Day.date(date) ?? Date() }, set: { date = Day.string($0) }), displayedComponents: .date)
                } header: {
                    Text(LS("值"))
                } footer: {
                    Text(LS("写入账本：%@", lifeEventText(date: date, type: kind.isEmpty ? "…" : kind, value: value.isEmpty ? "…" : value)))
                        .font(.caption.monospaced())
                }
            }
            .keyboardDone()
            .navigationTitle(LS("记一条变化"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LS("保存")) {
                        busy = true
                        Task {
                            let ok = await store.addLifeEvent(type: kind.trimmed, value: value.trimmed, date: date)
                            busy = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(kind.trimmed.isEmpty || value.trimmed.isEmpty || busy)
                }
            }
            .onAppear { if let t = type { kind = t } }
        }
    }
}
