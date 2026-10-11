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
                        HStack {
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
        .searchable(text: $query, prompt: LS("文件名"))
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
                CodeTextView(text: $text, editable: editing, find: find)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .navigationTitle(path.components(separatedBy: "/").last ?? path)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(editing)
        .toolbar {
            if editing {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LS("取消")) { if text != original { confirmDiscard = true } else { editing = false } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LS("保存")) { Task { await save() } }.disabled(text == original || saving)
                }
            } else if original != nil {
                ToolbarItem(placement: .primaryAction) { Button(LS("编辑")) { editing = true } }
            }
            if original != nil {
                ToolbarItem(placement: .secondaryAction) {
                    Button { find += 1 } label: { Label(LS("查找"), systemImage: "magnifyingglass") }
                }
            }
        }
        .confirmationDialog(LS("放弃修改？"), isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(LS("放弃修改"), role: .destructive) { text = original ?? ""; editing = false }
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

/// a plain-text view for long files: monospaced, no autocorrection, read-only until editing
struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    var editable: Bool
    /// bumped to open the find bar
    var find = 0

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        v.autocorrectionType = .no
        v.autocapitalizationType = .none
        v.smartQuotesType = .no
        v.smartDashesType = .no
        v.smartInsertDeleteType = .no
        v.spellCheckingType = .no
        v.alwaysBounceVertical = true
        v.keyboardDismissMode = .interactive
        v.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 40, right: 10)
        v.isFindInteractionEnabled = true
        v.delegate = context.coordinator
        v.text = text
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text }
        if context.coordinator.find != find {
            context.coordinator.find = find
            v.findInteraction?.presentFindNavigator(showingReplace: editable)
        }
        if v.isEditable != editable {
            v.isEditable = editable
            if editable { v.becomeFirstResponder() } else { v.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: CodeTextView
        var find = 0
        init(_ p: CodeTextView) { parent = p }
        func textViewDidChange(_ v: UITextView) { parent.text = v.text }
    }
}
