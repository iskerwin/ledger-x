import SwiftUI
import LedgerKit

/// 快速搜索 under the search box on 明细: tap to search, tap again to clear; + saves what is in the box;
/// press and hold to edit, move or delete. Saved in ledger-x.json, so every device has them.
struct QuickSearchBar: View {
    @EnvironmentObject var store: Store
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
            HStack(spacing: 8) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                    let on = now == s.query.trimmed
                    Button { q = on ? "" : s.query + " " } label: {
                        Text(s.name)
                            .font(.subheadline).lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, 6)
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
                        Label(LS("保存"), systemImage: "plus")
                            .font(.subheadline).labelStyle(.titleAndIcon)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .overlay(Capsule().stroke(Color.jade, lineWidth: 1))
                            .foregroundStyle(Color.jade)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
        .sheet(item: $editing) { e in QuickSearchSheet(edit: e) }
    }

    private func move(_ i: Int, _ d: Int) {
        var l = store.quickSearches
        guard l.indices.contains(i), l.indices.contains(i + d) else { return }
        l.swapAt(i, i + d)
        Task { await store.setQuickSearches(l, label: LS("调整快速搜索顺序")) }
    }

    private func remove(_ i: Int) {
        var l = store.quickSearches
        guard l.indices.contains(i) else { return }
        let s = l.remove(at: i)
        Task { await store.setQuickSearches(l, label: LS("删除快速搜索：%@", s.name)) }
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
    @EnvironmentObject var store: Store
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
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LS("保存")) { save() }.fontWeight(.semibold)
                        .disabled(edit.name.trimmed.isEmpty || edit.query.trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        var l = store.quickSearches
        let s = QuickSearch(name: edit.name.trimmed, query: edit.query.trimmed)
        if let i = edit.index, l.indices.contains(i) { l[i] = s } else { l.append(s) }
        let label = edit.index == nil ? LS("新增快速搜索：%@", s.name) : LS("修改快速搜索：%@", s.name)
        dismiss()
        Task { await store.setQuickSearches(l, label: label) }
    }
}
