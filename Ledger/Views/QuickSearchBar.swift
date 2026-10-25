import SwiftUI
import LedgerKit

/// 快速搜索 under the search box on 明细: tap to search, tap again to clear; + saves what is in the box;
/// press and hold to edit, move or delete. Saved in ledger-x.json, so every device has them.
struct QuickSearchBar: View {
    @Environment(Store.self) var store
    @Binding var q: String
    @State private var editing: QuickSearchEdit?

    var body: some View {
        let list = store.quickSearches
        let now = q.trimmed
        // nothing saved and nothing typed: no row (the hint is among the search examples)
        if !(list.isEmpty && now.isEmpty) { row(list, now) }
    }

    private func row(_ list: [QuickSearch], _ now: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.icon) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                    let on = now == s.query.trimmed
                    Button { q = on ? "" : s.query + " " } label: {
                        Label(s.name, systemImage: "line.3.horizontal.decrease.circle").labelStyle(ControlLabelStyle())
                            .font(.subheadline).lineLimit(1)
                            .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.icon)
                            .background(on ? Color.jade : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(on ? Color.onJade : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { editing = QuickSearchEdit(index: i, name: s.name, query: s.query) } label: { Label(LS("编辑"), systemImage: "pencil") }
                        if i > 0 { Button { move(i, -1) } label: { Label(LS("前移"), systemImage: "arrow.left") } }
                        if i < list.count - 1 { Button { move(i, 1) } label: { Label(LS("后移"), systemImage: "arrow.right") } }
                        Button(role: .destructive) { remove(i) } label: { Label(LS("删除"), systemImage: "trash") }
                    }
                }
                if !now.isEmpty && !list.contains(where: { $0.query.trimmed == now }) {
                    Button { editing = QuickSearchEdit(index: nil, name: "", query: now) } label: {
                        Label(LS("保存"), systemImage: "plus").labelStyle(ControlLabelStyle())
                            .font(.subheadline).labelStyle(.titleAndIcon)
                            .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.icon)
                            .overlay(Capsule().stroke(Color.jade, lineWidth: 1))
                            .foregroundStyle(Color.jade)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AppSpacing.content).padding(.vertical, AppSpacing.icon)
        }
        .sheet(item: $editing) { e in QuickSearchSheet(edit: e) }
    }

    private func move(_ i: Int, _ d: Int) {
        let l = store.quickSearches
        guard l.indices.contains(i), l.indices.contains(i + d) else { return }
        Task { await store.moveQuickSearch(l[i], by: d) }
    }

    private func remove(_ i: Int) {
        let l = store.quickSearches
        guard l.indices.contains(i) else { return }
        Task { await store.removeQuickSearch(l[i]) }
    }
}

struct QuickSearchEdit: Identifiable {
    let id = UUID()
    /// nil = a new one
    let index: Int?
    var name: String
    var query: String
}

struct QuickSearchSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    @State var edit: QuickSearchEdit
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(LS("名称，如「出差和旅行」"), text: $edit.name).focused($focused)
                    TextField(LS("搜索条件"), text: $edit.query, axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text(LS("写法和搜索框一样：空格隔开表示同时满足，| 表示任一（#出差|#旅行）；本月、上月、今年、近30天按当天计算，保存后一直有效。"))
                }
            }
            .navigationTitle(edit.index == nil ? LS("保存为快速搜索") : LS("编辑快速搜索"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { SaveLabel() }
                        .disabled(edit.name.trimmed.isEmpty || edit.query.trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .formSheet()
    }

    private func save() {
        let l = store.quickSearches
        let s = QuickSearch(name: edit.name.trimmed, query: edit.query.trimmed)
        let original = edit.index.flatMap { l.indices.contains($0) ? l[$0] : nil }
        let label = original == nil ? LS("新增快速搜索：%@", s.name) : LS("修改快速搜索：%@", s.name)
        dismiss()
        Task { await store.saveQuickSearch(s, replacing: original, label: label) }
    }
}
