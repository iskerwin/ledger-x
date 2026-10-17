import SwiftUI
import UIKit
import LedgerKit

struct DraftRecoverySheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var workspace = DraftWorkspace()
    @State private var removing: String?
    @State private var opening = false
    @State private var source: EntrySourceTarget?

    var body: some View {
        NavigationStack {
            List {
                if let creation = workspace.creation {
                    Section(LS("新建交易草稿")) {
                        Button {
                            store.persistActiveDraft()
                            store.restoreCreationDraft()
                            store.openAdd(full: store.needsFullForm(store.draft))
                            dismiss()
                        } label: { row(creation) }
                        .contextMenu {
                            Button { copy(creation) } label: { Label(LS("复制源文本"), systemImage: "doc.on.clipboard") }
                            Button(LS("删除草稿"), role: .destructive) { removing = "" }
                        }
                    }
                }
                if !workspace.edits.isEmpty {
                    Section(LS("交易编辑草稿")) {
                        ForEach(workspace.edits.keys.sorted(), id: \.self) { key in
                            if let session = workspace.edits[key] {
                                Button {
                                    guard !opening else { return }
                                    opening = true
                                    Task {
                                        if await store.resumeDraft(key) { dismiss() }
                                        opening = false
                                    }
                                } label: { row(session) }
                                .contextMenu {
                                    Button { copy(session) } label: { Label(LS("复制源文本"), systemImage: "doc.on.clipboard") }
                                    Button(LS("删除草稿"), role: .destructive) { removing = key }
                                }
                            }
                        }
                    }
                }
                if !workspace.sources.isEmpty {
                    Section(LS("源文本编辑草稿")) {
                        ForEach(workspace.sources.keys.sorted(), id: \.self) { key in
                            if let session = workspace.sources[key] {
                                Button {
                                    let original = parseFile(session.original, file: session.file).entries
                                    if original.count == 1,
                                       let current = EntryLocator(original[0]).resolve(in: store.L?.entries ?? []) {
                                        source = EntrySourceTarget(entry: current, ledgerID: store.cfg.id, editing: true)
                                    } else { store.show(LS("原记录已变化，草稿已保留。可复制草稿内容后核对。")) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(session.label).foregroundStyle(.primary)
                                        Text(session.file).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .contextMenu {
                                    Button(LS("复制源文本")) { UIPasteboard.general.string = session.text; Haptics.success() }
                                    Button(LS("删除草稿"), role: .destructive) { removing = "source:" + key }
                                }
                            }
                        }
                    }
                }
                if workspace.creation == nil && workspace.edits.isEmpty && workspace.sources.isEmpty {
                    Text(LS("没有保留的草稿")).foregroundStyle(.secondary)
                }
                Section {
                    Text(LS("草稿仅保存在本机，并按账本分别保存。原交易发生变化时，可先复制草稿内容核对。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(opening)
            .navigationTitle(LS("草稿"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(LS("完成")) { dismiss() } } }
            .confirmationDialog(LS("删除这份草稿？"), isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            ), titleVisibility: .visible, presenting: removing) { key in
                Button(LS("删除草稿"), role: .destructive) { remove(key) }
                Button(LS("取消"), role: .cancel) {}
            }
            .overlay(alignment: .bottom) { ToastView() }
            .sheet(item: $source, onDismiss: { workspace = store.draftWorkspace }) { EntrySourceSheet(target: $0) }
            .onAppear { store.persistActiveDraft(); workspace = store.draftWorkspace }
            .onChange(of: store.cfg.id) { _, _ in dismiss() }
        }
    }

    private func row(_ session: DraftSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text([session.draft.payee, session.draft.narration].filter { !$0.isEmpty }.joined(separator: " · ").isEmpty
                 ? session.draft.kind.label : [session.draft.payee, session.draft.narration].filter { !$0.isEmpty }.joined(separator: " · "))
                .foregroundStyle(.primary).lineLimit(2)
            Text(session.draft.date + " · " + session.draft.amount + " " + session.draft.currency)
                .font(.caption).foregroundStyle(.secondary).sensitive()
            if let r = session.draft.replacing { Text(r.path).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func copy(_ session: DraftSession) {
        guard let L = store.L, let D = store.D else { return }
        let text = draftText(session.draft, L, D, explicit: store.explicitAmounts)
        UIPasteboard.general.string = text.isEmpty
            ? String(data: (try? JSONEncoder().encode(session.draft)) ?? Data(), encoding: .utf8) : text
        Haptics.success()
        store.show(LS("已复制到剪贴板"))
    }

    private func remove(_ key: String) {
        if key.hasPrefix("source:") {
            store.draftWorkspace.sources[String(key.dropFirst(7))] = nil
        } else if key.isEmpty {
            if store.draft.replacing == nil { store.discardActiveDraft() }
            else { store.draftWorkspace.creation = nil }
        } else {
            if let r = store.draft.replacing, DraftWorkspace.editKey(r) == key { store.discardActiveDraft() }
            else { store.draftWorkspace.edits[key] = nil }
        }
        if !store.demo { Prefs.set(store.pk("draftWorkspace"), store.draftWorkspace) }
        workspace = store.draftWorkspace
        removing = nil
    }
}
