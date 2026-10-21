import SwiftUI
import LedgerKit

/// changes made from this device, newest first; each can be taken back
struct HistoryView: View {
    @EnvironmentObject var store: Store
    @State private var confirming: ChangeRecord?

    var body: some View {
        List {
            Section {
                if store.history.isEmpty {
                    Text(LS("还没有在本机做过修改")).foregroundStyle(.secondary)
                }
                ForEach(store.history) { r in
                    NavigationLink { HistoryDetailView(id: r.id) } label: { HistoryRow(r: r) }
                        .swipeActions {
                            if r.undone == nil { Button { confirming = r } label: { Label(LS("撤回"), systemImage: "arrow.uturn.backward") }.tint(.orange) }
                        }
                }
            } footer: {
                Text(LS("记录本机通过 App 做的修改（最多 100 项）。撤回会生成一次新的提交，把这次改动的内容改回原样；之后又被改过的内容不会被覆盖。在电脑上做的修改不在这里。"))
            }
        }
        .navigationTitle(LS("最近改动"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(LS("撤回这次改动？"), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { r in
            Button(role: .destructive) { Task { await store.revert(r.id) } } label: { Text(LS("撤回")) }
        } message: { r in
            Text(r.label)
        }
    }
}

private struct HistoryRow: View {
    let r: ChangeRecord
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.detail) {
            Text(r.label).font(.subheadline).lineLimit(2)
                .foregroundStyle(r.undone == nil ? Color.primary : Color.secondary)
            HStack(spacing: AppSpacing.icon) {
                Text(r.time.formatted(date: .abbreviated, time: .shortened))
                Text(r.files.count == 1 ? r.files[0] : LS("%@ 个文件", r.files.count)).lineLimit(1)
                if r.undone != nil { Text(LS("已撤回")).foregroundStyle(Color.warn) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, AppSpacing.detail)
    }
}

struct HistoryDetailView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var confirm = false

    var body: some View {
        let r = store.history.first { $0.id == id }
        List {
            if let r = r {
                Section {
                    LabeledContent(LS("时间"), value: r.time.formatted(date: .abbreviated, time: .shortened))
                    if let u = r.undone { LabeledContent(LS("已撤回"), value: u.formatted(date: .abbreviated, time: .shortened)) }
                } header: {
                    Text(r.label).textCase(nil)
                }
                ForEach(Array(changeHunks(r).enumerated()), id: \.offset) { _, h in
                    Section(h.path) { HunkView(h: h) }
                }
                if r.undone == nil {
                    Section {
                        Button(role: .destructive) { confirm = true } label: {
                            Label(LS("撤回这次改动"), systemImage: "arrow.uturn.backward").labelStyle(ControlLabelStyle())
                        }
                    } footer: {
                        Text(LS("撤回前同样会做提交前检查。"))
                    }
                }
            }
        }
        .navigationTitle(LS("改动详情"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(LS("撤回这次改动？"), isPresented: $confirm, titleVisibility: .visible) {
            Button(role: .destructive) {
                Task { if await store.revert(id) { dismiss() } }
            } label: { Text(LS("撤回")) }
        }
    }
}

/// the lines a change removed (−) and added (+), with a little context
private struct HunkView: View {
    let h: ChangeHunk
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.detail) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l.mark + " " + l.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(l.mark == "+" ? Color.gain : l.mark == "−" ? Color.loss : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppSpacing.detail)
                    .background(l.mark == "+" ? Color.gain.opacity(0.08) : l.mark == "−" ? Color.loss.opacity(0.08) : .clear)
            }
        }
        .sensitive()
    }

    private var lines: [(mark: String, text: String)] {
        // at most two lines of context on each side
        h.context.before.suffix(2).map { (" ", $0) }
            + h.removed.map { ("−", $0) } + h.added.map { ("+", $0) }
            + h.context.after.prefix(2).map { (" ", $0) }
    }
}
