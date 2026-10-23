import SwiftUI
import UIKit
import LedgerKit

/// every ledger file in the repository, to read or edit as plain text
struct SourceFilesView: View {
    @EnvironmentObject var store: Store
    @State private var query = ""

    var body: some View {
        let files = (store.tree?.files.keys.filter(isLedgerFile) ?? [])
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .sorted { a, b in
                // the main file first, then by folder
                if a == store.main { return true }
                if b == store.main { return false }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
        let pendingPaths = Set(store.pending.map { $0.path })
        List {
            Section {
                ForEach(files, id: \.self) { path in
                    NavigationLink { SourceFileView(path: path) } label: {
                        HStack(spacing: AppSpacing.icon) {
                            Image(systemName: path.hasSuffix(".json") ? "curlybraces" : path.hasSuffix(".bql") ? "magnifyingglass" : "doc.plaintext")
                                .foregroundStyle(.secondary).frame(width: 22)
                            Text(path).font(.subheadline.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if pendingPaths.contains(path) { Image(systemName: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(Color.warn) }
                        }
                    }
                }
            } footer: {
                Text(LS("这里显示的是包含待同步修改后的内容。保存时只提交改动的部分，并先做提交前检查；同一处在别处被改过时不会覆盖。"))
            }
        }
        .appSearchable(text: $query, prompt: LS("文件名"))
        .navigationTitle(LS("源文件"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SourceFileView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var original: String?
    @State private var text = ""
    @State private var editing = false
    @State private var failed: String?
    @State private var saving = false
    @State private var confirmDiscard = false
    @State private var find = 0

    var body: some View {
        Group {
            if let f = failed {
                ContentUnavailableView(LS("无法读取"), systemImage: "exclamationmark.triangle", description: Text(f))
            } else if original == nil {
                ProgressView()
            } else {
                CodeTextView(text: $text, language: .beancount, editable: editing, find: find)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .navigationTitle(path.components(separatedBy: "/").last ?? path)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(editing)
        .toolbar {
            if editing {
                ToolbarItem(placement: .cancellationAction) {
                    Button { if text != original { confirmDiscard = true } else { editing = false } } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { SaveLabel() }.disabled(text == original || saving)
                }
            } else if original != nil {
                ToolbarItem(placement: .primaryAction) { Button { editing = true } label: { Label(LS("编辑"), systemImage: "pencil").labelStyle(ControlLabelStyle()) } }
            }
            if original != nil {
                ToolbarItem(placement: .secondaryAction) {
                    Button { find += 1 } label: { Label(LS("查找"), systemImage: "magnifyingglass").labelStyle(ControlLabelStyle()) }
                }
            }
        }
        .confirmationDialog(LS("放弃修改？"), isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(role: .destructive) { text = original ?? ""; editing = false } label: { Text(LS("放弃修改")) }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let t = try await store.fileText(path)
            original = t
            text = t
        } catch {
            failed = error.localizedDescription
        }
    }

    private func save() async {
        guard let o = original, text != o else { return }
        saving = true
        defer { saving = false }
        // only the changed regions, each with enough context to find it again on the server
        var ops = revertOps(path: path, before: text, after: o)
        guard !ops.isEmpty else { editing = false; return }
        for i in ops.indices {
            ops[i].label = LS("编辑源文件：%@", path)
            if i > 0 { ops[i].silent = true }
        }
        if await store.commit(ops, word: LS("已保存")) {
            original = text
            editing = false
        }
    }
}

