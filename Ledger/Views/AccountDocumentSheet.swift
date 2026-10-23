import SwiftUI
import UniformTypeIdentifiers
import LedgerKit

extension Store {
    /// Upload to the selected ledger, then record an account document through the normal review and undo flow.
    /// `folder` and `fileName` are one path segment each; the directive line is unchanged.
    func addAccountDocument(account: String, date: String, folder: String, fileName: String, data: Data) async throws -> Bool {
        guard let path = documentStoragePath(folder: folder, fileName: fileName) else { return false }
        if tree?.files[path] != nil { return false }
        let ledgerID = cfg.id
        let destination = backend
        guard var ops = makeOps(documentText(date: date, account: account, path: path),
                                extra: OpExtra(label: LS("添加票据：%@", fileName)), single: false) else { return false }
        for i in ops.indices where ops[i].kind == .insert {
            ops[i].text = ops[i].text?.replacingOccurrences(of: quoted(path), with: quoted(relativeDocumentPath(path, from: ops[i].path)))
        }
        guard let checked = await review(ops), cfg.id == ledgerID else { return false }
        try await destination.writeData(path, data: data, message: LS("附件：%@", fileName))
        guard cfg.id == ledgerID else { return false }
        return await commit(checked, word: LS("已添加票据"), checked: true)
    }
}

/// Hides the keyboard without saving. The return key says 完成 and does the same; the top-right button confirms.
extension View {
    func documentKeyboardDismiss() -> some View {
        scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button { hideKeyboard() } label: {
                        Label(LS("收起键盘"), systemImage: "keyboard.chevron.compact.down").labelStyle(ControlLabelStyle())
                    }
                    .accessibilityIdentifier("document.hideKeyboard")
                }
            }
    }
}

func documentLocationIssue(folder: String, stem: String, ext: String, existing: Set<String>, isSaving: Bool = false) -> String? {
    // The confirmed path becomes occupied by this save before the sheet finishes dismissing.
    // Resume live validation only if saving fails and the form becomes editable again.
    guard !isSaving else { return nil }
    switch documentNameIssue(folder) {
    case .empty: return LS("请填写文件夹")
    case .separator: return LS("文件夹不能包含斜线、引号或换行")
    case .reserved: return LS("文件夹不能是 . 或 ..")
    case nil: break
    }
    switch documentNameIssue(stem) {
    case .empty: return LS("请填写文件名")
    case .separator: return LS("文件名不能包含斜线、引号或换行")
    case .reserved: return LS("文件名不能是 . 或 ..")
    case nil: break
    }
    let fileName = documentFileName(stem: stem, ext: ext)
    guard let path = documentStoragePath(folder: folder, fileName: fileName) else { return LS("请填写文件名") }
    if existing.contains(path) { return LS("这个文件已经在账本里，请改一个名字") }
    return nil
}

/// Account documents need not belong to a transaction (for example a bank's monthly statement).
struct AccountDocumentSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let account: String
    @State private var date: String
    @State private var pickedName = ""
    @State private var data: Data?
    @State private var choosing = false
    @State private var busy = false
    @State private var error: String?
    @State private var folder: String
    @State private var fileStem: String
    @State private var fileExt = ""
    @State private var stemEdited = false

    init(account: String) {
        self.account = account
        let folder = documentFolder(for: account)
        let date = Day.today()
        _folder = State(initialValue: folder)
        _date = State(initialValue: date)
        _fileStem = State(initialValue: documentFileStem(preferredDocumentFileName(folder: folder, date: date, ext: "", existingPaths: []), ext: ""))
    }

    private var takenPaths: Set<String> {
        guard let files = store.tree?.files else { return [] }
        return Set(files.keys)
    }

    private var savedFileName: String { documentFileName(stem: fileStem, ext: fileExt) }

    private var pathIssue: String? {
        documentLocationIssue(folder: folder, stem: fileStem, ext: fileExt, existing: takenPaths, isSaving: busy)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(LS("账户"), value: acctDisplay(account))
                    DateField(value: $date)
                    Button { choosing = true } label: {
                        Label(pickedName.isEmpty ? LS("从文件选择") : pickedName, systemImage: "doc.badge.plus").labelStyle(ControlLabelStyle())
                    }
                    if let data = data {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DocumentSaveToRow(
                        folder: $folder,
                        suggestedFolder: documentFolder(for: account),
                        folders: documentFolders(in: takenPaths),
                        onCommit: { refreshDefaultName() }
                    )
                    DocumentFileNameRow(fileStem: $fileStem, stemEdited: $stemEdited, fileExt: fileExt)
                    if let pathIssue {
                        Text(pathIssue).foregroundStyle(Color.loss)
                    }
                } footer: {
                    Text(LS("选择 PDF、图片或其他文件。可以改保存位置和文件名；右上角「保存」才写入，不会改变账户余额。键盘回车「完成」和「收起键盘」只收起键盘。") + "\n" + LS(attachmentFormatsHint))
                }
                if let error = error { Section { Text(error).foregroundStyle(Color.loss) } }
            }
            .disabled(busy)
            .documentKeyboardDismiss()
            .navigationTitle(LS("添加票据 / 对账单"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: {
                        if busy { ProgressView() } else { Label(LS("保存"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }
                    }
                    .disabled(data == nil || busy || pathIssue != nil)
                    .accessibilityIdentifier("document.save")
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
                    pickedName = url.lastPathComponent
                    fileExt = normalizedDocumentExtension(url.pathExtension)
                    error = nil
                    refreshDefaultName()
                } catch { self.error = error.localizedDescription }
            }
            .interactiveDismissDisabled(busy)
            .onAppear { refreshDefaultName() }
            .onChange(of: date) { _, _ in refreshDefaultName() }
            .onChange(of: store.tree?.sha) { _, _ in refreshDefaultName() }
            .onChange(of: store.cfg.id) { _, _ in dismiss() }
        }
    }

    /// Rewrites the suggested file name from the folder and date, until the name has been edited by hand.
    private func refreshDefaultName() {
        guard !stemEdited, !busy else { return }
        let full = preferredDocumentFileName(folder: folder, date: date, ext: fileExt, existingPaths: takenPaths)
        fileStem = documentFileStem(full, ext: fileExt)
    }

    private func save() {
        guard let data = data, !busy, pathIssue == nil, let path = documentStoragePath(folder: folder, fileName: savedFileName) else { return }
        busy = true
        let fileName = savedFileName
        let folder = self.folder
        let date = self.date
        Task {
            error = nil
            do {
                let ok = try await store.addAccountDocument(account: account, date: date, folder: folder, fileName: fileName, data: data)
                if ok {
                    // Keep the form frozen throughout dismissal, including incoming tree updates.
                    dismiss()
                    return
                }
                if store.tree?.files[path] != nil { error = LS("这个文件已经在账本里，请改一个名字") }
            } catch { self.error = LS("上传失败：%@", error.localizedDescription) }
            busy = false
        }
    }
}

/// One form row. Tapping opens the folder list; 完成 there applies the choice.
struct DocumentSaveToRow: View {
    @Binding var folder: String
    let suggestedFolder: String
    let folders: [String]
    var onCommit: () -> Void
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            HStack(spacing: AppSpacing.icon) {
                ControlIcon(systemName: "folder")
                Text(LS("保存到"))
                Spacer(minLength: AppSpacing.icon)
                Text(folderDisplay)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("document.saveTo")
        .sheet(isPresented: $choosing) {
            DocumentFolderSheet(folders: folders, suggestion: suggestedFolder, current: folder) { name in
                folder = name
                onCommit()
            }
            .pickerSheet()
        }
    }

    private var folderDisplay: String {
        let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? LS("请选择") : "documents/\(name)/"
    }
}

/// The file name without its extension. The extension is shown beside the field and cannot be edited away.
struct DocumentFileNameRow: View {
    @Binding var fileStem: String
    @Binding var stemEdited: Bool
    let fileExt: String

    var body: some View {
        HStack(spacing: AppSpacing.icon) {
            Text(LS("文件名"))
            TextField(LS("文件名"), text: stemBinding)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { hideKeyboard() }
                .accessibilityIdentifier("document.fileName")
            if !normalizedDocumentExtension(fileExt).isEmpty {
                Text("." + normalizedDocumentExtension(fileExt))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stemBinding: Binding<String> {
        Binding(
            get: { fileStem },
            set: { newValue in
                let cleaned = strippingLockedExtension(newValue)
                if cleaned != fileStem {
                    stemEdited = true
                    fileStem = cleaned
                }
            }
        )
    }

    /// Pasting `name.pdf` must not become `name.pdf.pdf`.
    private func strippingLockedExtension(_ raw: String) -> String {
        let ext = normalizedDocumentExtension(fileExt)
        guard !ext.isEmpty, raw.lowercased().hasSuffix("." + ext) else { return raw }
        return String(raw.dropLast(ext.count + 1))
    }
}

/// Existing `documents/` folders, plus a new-folder field prefilled with the suggestion.
/// Highlighting a row does not apply it: 完成 does, 取消 does not.
struct DocumentFolderSheet: View {
    let folders: [String]
    let suggestion: String
    let current: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var draft: String
    @State private var typed = ""

    init(folders: [String], suggestion: String, current: String, onSelect: @escaping (String) -> Void) {
        self.folders = folders
        self.suggestion = suggestion
        self.current = current
        self.onSelect = onSelect
        _draft = State(initialValue: current.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var rows: [String] {
        var list = folders
        let name = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if documentNameIssue(name) == nil, !list.contains(name) { list.insert(name, at: 0) }
        return list
    }

    private var confirmName: String {
        creating ? typed.trimmingCharacters(in: .whitespacesAndNewlines) : draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var confirmIssue: String? {
        switch documentNameIssue(confirmName) {
        case .empty: return LS("请填写文件夹")
        case .separator: return LS("文件夹不能包含斜线、引号或换行")
        case .reserved: return LS("文件夹不能是 . 或 ..")
        case nil: return nil
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if creating {
                    Section {
                        TextField(LS("文件夹名称"), text: $typed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { hideKeyboard() }
                            .accessibilityIdentifier("document.newFolder")
                        if let confirmIssue {
                            Text(confirmIssue).font(.caption).foregroundStyle(Color.loss)
                        }
                    } footer: {
                        Text(LS("只写文件夹名，不要加斜线。右上角「完成」才用这个名字。键盘回车「完成」和「收起键盘」只收起键盘。"))
                    }
                } else {
                    Section {
                        if rows.isEmpty {
                            Text(LS("账本里 documents 下还没有文件夹")).foregroundStyle(.secondary)
                        }
                        ForEach(rows, id: \.self) { name in
                            Button { draft = name } label: {
                                HStack(spacing: AppSpacing.icon) {
                                    ControlIcon(systemName: "folder")
                                    Text("documents/\(name)/").lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: AppSpacing.icon)
                                    if name == draft {
                                        Image(systemName: "checkmark").foregroundStyle(Color.jade).accessibilityHidden(true)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("document.folder." + name)
                        }
                        Button {
                            typed = suggestion
                            creating = true
                        } label: {
                            Label(LS("新建文件夹"), systemImage: "folder.badge.plus").labelStyle(ControlLabelStyle())
                        }
                        .accessibilityIdentifier("document.newFolder.open")
                    } footer: {
                        if folders.isEmpty && !rows.isEmpty {
                            Text(LS("账本里 documents 下还没有文件夹"))
                        }
                    }
                }
            }
            .documentKeyboardDismiss()
            .navigationTitle(creating ? LS("新建文件夹") : LS("保存到"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if creating { creating = false } else { dismiss() }
                    } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) }
                    .accessibilityIdentifier("document.folder.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard confirmIssue == nil else { return }
                        onSelect(confirmName)
                        dismiss()
                    } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }
                    .disabled(confirmIssue != nil)
                    .accessibilityIdentifier("document.folder.done")
                }
            }
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
                        VStack(alignment: .leading, spacing: AppSpacing.detail) {
                            Label(((doc.path ?? "") as NSString).lastPathComponent, systemImage: "doc").labelStyle(ControlLabelStyle()).lineLimit(2)
                            Text(doc.date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .entryActions(doc)
                }
            }
            .navigationTitle(LS("票据与对账单"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel(LS("添加票据 / 对账单"))
                }
            }
            .sheet(item: $viewing) { DocumentViewer(path: $0.path) }
            .sheet(isPresented: $adding) { AccountDocumentSheet(account: account) }
        }
    }
}
