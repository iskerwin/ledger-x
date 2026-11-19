import SwiftUI
import LedgerKit

/// 快速搜索 beside the window's search: the ones saved on the phone or here (ledger-x.json, so every device has them).
/// Picking one searches for it, picking it again clears the search; the current search can be saved, and the list is
/// put in order, changed and pared down in 管理快速搜索.
struct QuickSearchMenu: View {
    let config: LedgerXConfig?
    let folder: URL
    @Binding var filter: String
    @State private var editing: QuickSearchEdit?
    @State private var managing = false

    var body: some View {
        let list = config?.searches ?? []
        let now = filter.trimmed
        Menu {
            ForEach(list) { search in
                Toggle(search.name, isOn: Binding(get: { now == search.query.trimmed },
                                                  set: { filter = $0 ? search.query : "" }))
            }
            if !list.isEmpty { Divider() }
            Button(LS("保存当前搜索…")) { editing = QuickSearchEdit(original: nil, name: "", query: now) }
                .disabled(now.isEmpty || list.contains { $0.query.trimmed == now })
            Button(LS("管理快速搜索…")) { managing = true }.disabled(list.isEmpty)
        } label: {
            Label(LS("快速搜索"), systemImage: "bookmark")
        }
        .help(LS("快速搜索"))
        .sheet(item: $editing) { QuickSearchEditor(edit: $0, folder: folder) }
        .sheet(isPresented: $managing) { QuickSearchManager(list: list, folder: folder) }
    }
}

struct QuickSearchEdit: Identifiable {
    let id = UUID()
    /// the one being changed; nil for a new one
    let original: QuickSearch?
    var name: String
    var query: String
}

/// what a change to the list writes: into ledger-x.json, one step of 编辑 › 撤销
@MainActor
private func saveSearches(folder: URL, _ change: (inout LedgerXConfig) -> Void) throws {
    let save = try prepareFolderConfig(folder: folder, change).get()
    try SaveUndo.commit(save, folder: folder, name: LS("修改快速搜索"))
}

private struct QuickSearchEditor: View {
    @State var edit: QuickSearchEdit
    let folder: URL
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(edit.original == nil ? LS("保存为快速搜索") : LS("编辑快速搜索")).font(.headline)
            Form {
                TextField(LS("名称"), text: $edit.name, prompt: Text(LS("名称，如「出差和旅行」")))
                TextField(LS("搜索条件"), text: $edit.query, axis: .vertical).font(.body.monospaced())
            }
            HStack {
                Spacer()
                Button(LS("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(LS("保存")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(edit.name.trimmed.isEmpty || edit.query.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .alert(message, isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) {}
    }

    private func save() {
        let search = QuickSearch(name: edit.name.trimmed, query: edit.query.trimmed)
        do {
            try saveSearches(folder: folder) { $0.saveSearch(search, replacing: edit.original) }
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct QuickSearchManager: View {
    let list: [QuickSearch]
    let folder: URL
    @Environment(\.dismiss) private var dismiss
    @State private var editing: QuickSearchEdit?
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LS("管理快速搜索")).font(.headline)
            List {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, search in
                    HStack {
                        Text(search.name)
                        Spacer()
                        Text(search.query).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Menu {
                            Button(LS("编辑…")) { editing = QuickSearchEdit(original: search, name: search.name, query: search.query) }
                            Button(LS("上移")) { write { $0.moveSearch(search, by: -1) } }.disabled(i == 0)
                            Button(LS("下移")) { write { $0.moveSearch(search, by: 1) } }.disabled(i == list.count - 1)
                            Divider()
                            Button(LS("删除"), role: .destructive) { write { $0.removeSearch(search) } }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel(LS("更多"))
                    }
                }
            }
            .frame(minHeight: 200)
            HStack {
                Spacer()
                Button(LS("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .sheet(item: $editing) { QuickSearchEditor(edit: $0, folder: folder) }
        .alert(message, isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) {}
    }

    private func write(_ change: (inout LedgerXConfig) -> Void) {
        do { try saveSearches(folder: folder, change) } catch { message = error.localizedDescription }
    }
}
