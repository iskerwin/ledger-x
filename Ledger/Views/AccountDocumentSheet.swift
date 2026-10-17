import SwiftUI
import UniformTypeIdentifiers
import LedgerKit

extension Store {
    /// Upload to the selected ledger, then record an account document through the normal review and undo flow.
    func addAccountDocument(account: String, date: String, name: String, data: Data) async throws -> Bool {
        let ledgerID = cfg.id
        let destination = backend
        let ext = (name as NSString).pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let stem = (name as NSString).deletingPathExtension.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let path = "documents/\(date.prefix(4))/\(date)-\(stem.isEmpty ? "document" : String(stem.prefix(48)))-\(UUID().uuidString.lowercased())" + (ext.isEmpty ? "" : "." + ext)
        guard var ops = makeOps(documentText(date: date, account: account, path: path),
                                extra: OpExtra(label: LS("添加票据：%@", name)), single: false) else { return false }
        for i in ops.indices where ops[i].kind == .insert {
            ops[i].text = ops[i].text?.replacingOccurrences(of: quoted(path), with: quoted(relativeDocumentPath(path, from: ops[i].path)))
        }
        guard let checked = await review(ops), cfg.id == ledgerID else { return false }
        try await destination.writeData(path, data: data, message: LS("附件：%@", name))
        guard cfg.id == ledgerID else { return false }
        return await commit(checked, word: LS("已添加票据"), checked: true)
    }
}

/// Account documents need not belong to a transaction (for example a bank's monthly statement).
struct AccountDocumentSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let account: String
    @State private var date = Day.today()
    @State private var fileName = ""
    @State private var data: Data?
    @State private var choosing = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(LS("账户"), value: acctDisplay(account))
                    DateField(value: $date)
                    Button { choosing = true } label: {
                        Label(fileName.isEmpty ? LS("从文件选择") : fileName, systemImage: "doc.badge.plus")
                    }
                    if let data = data {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(LS("选择 PDF、图片或其他文件，作为账户票据保存；不会改变账户余额。"))
                }
                if let error = error { Section { Text(error).foregroundStyle(Color.loss) } }
            }
            .disabled(busy)
            .navigationTitle(LS("添加票据 / 对账单"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LS("取消")) { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: {
                        if busy { ProgressView() } else { Text(LS("保存")) }
                    }.disabled(data == nil || busy)
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.item]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let bytes = try Data(contentsOf: url)
                    guard !bytes.isEmpty else { error = LS("文件为空，请重新选择"); return }
                    data = bytes
                    fileName = url.lastPathComponent
                    error = nil
                } catch { self.error = error.localizedDescription }
            }
            .interactiveDismissDisabled(busy)
            .onChange(of: store.cfg.id) { _, _ in dismiss() }
        }
    }

    private func save() {
        guard let data = data, !busy else { return }
        busy = true
        Task {
            error = nil
            do {
                let ok = try await store.addAccountDocument(account: account, date: date, name: fileName, data: data)
                if ok { dismiss() }
            } catch { self.error = LS("上传失败：%@", error.localizedDescription) }
            busy = false
        }
    }
}

/// Also reachable from the credit card's bill, without finding the document among transactions first.
struct AccountDocumentsSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let account: String
    @State private var viewing: DocItem?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                let docs = (store.L?.documents ?? []).filter { $0.account == account }.sorted { $0.date > $1.date }
                if docs.isEmpty { Text(LS("还没有票据，可添加银行对账单或其他文件")).foregroundStyle(.secondary) }
                ForEach(docs, id: \.id) { doc in
                    Button {
                        if let path = documentRepoPath(doc) { viewing = DocItem(path: path) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(((doc.path ?? "") as NSString).lastPathComponent).lineLimit(2)
                            Text(doc.date).font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(documentRepoPath(doc) == nil)
                }
            }
            .navigationTitle(LS("票据与对账单"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LS("完成")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel(LS("添加票据 / 对账单"))
                }
            }
            .sheet(item: $viewing) { DocumentViewer(path: $0.path) }
            .sheet(isPresented: $adding) { AccountDocumentSheet(account: account) }
        }
    }
}
