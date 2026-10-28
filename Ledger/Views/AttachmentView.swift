import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import LedgerKit

// Receipts and other files attached to a transaction: the file goes to documents/<folder>/
// in the ledger, and a `document` directive linked with the transaction's ^link points at it.
// The folder and the directive account follow the paying account (the From side of a transfer).

/// repository path of a document directive's file (relative to the file the directive is in)
func documentRepoPath(_ e: Entry) -> String? {
    guard let path = e.path else { return nil }
    return documentPath(path, from: e.file)
}

func relativePath(_ target: String, from file: String) -> String {
    relativeDocumentPath(target, from: file)
}

extension Store {
    /// documents linked to a transaction. Links that tie a whole group together (a reimbursement, petty cash,
    /// a refund, a subscription, a month's salary) don't make a document this transaction's own.
    func documents(for t: Entry) -> [Entry] {
        guard let L = L else { return [] }
        let links = Set(t.links.filter { [.document, .other].contains(LinkRole.of($0)) && !isSalaryLink($0) })
        if links.isEmpty { return [] }
        return L.entries.filter { $0.type == .document && !links.isDisjoint(with: $0.links) }
    }

    static func attachmentDataKind(_ id: UUID) -> String { "attachment-" + id.uuidString }

    /// Read from disk once per ledger, then from memory: views ask for this on every redraw, and reading it
    /// with the photo inside took long enough to stall the frames around an upload.
    func attachmentJobs() -> [AttachmentUpload] {
        let ledger = cfg.id
        if let cached = attachmentJobCache, cached.ledger == ledger { return cached.jobs }
        var jobs = RecoveryFiles.load([AttachmentUpload].self, kind: "attachments", ledger: ledger) ?? []
        var inline = false, moved = true
        for i in jobs.indices {
            if jobs[i].data.isEmpty {
                jobs[i].data = RecoveryFiles.loadData(kind: Self.attachmentDataKind(jobs[i].id), ledger: ledger) ?? Data()
            } else {
                // saved before the bytes had a file of their own: move them out
                inline = true
                if (try? RecoveryFiles.saveData(jobs[i].data, kind: Self.attachmentDataKind(jobs[i].id), ledger: ledger)) == nil { moved = false }
            }
        }
        // only once every photo is safely in its own file does the list lose its inline copy
        if inline && moved { try? RecoveryFiles.save(jobs, kind: "attachments", ledger: ledger) }
        attachmentJobCache = (ledger, jobs)
        return jobs
    }

    func attachmentTakenPaths(excluding id: UUID? = nil) -> Set<String> {
        var paths = Set(tree?.files.keys.map { $0 } ?? [])
        let jobs = attachmentJobs()
        let own = jobs.first(where: { $0.id == id })
        if let own, own.uploaded || own.uploadStarted == true {
            // An uncertain response is verified against the bytes on retry.
            paths.remove(own.path)
        }
        paths.formUnion(L?.documents.compactMap { document -> String? in
            guard let path = documentRepoPath(document) else { return nil }
            if let own, own.uploaded, path == own.path, document.links.contains(own.link),
               document.account == own.account, document.date == own.date { return nil }
            return path
        } ?? [])
        paths.formUnion(jobs.filter { $0.id != id }.map(\.path))
        return paths
    }

    private func saveAttachmentJob(_ job: AttachmentUpload, remove: Bool = false) throws {
        guard job.ledgerID == cfg.id else { throw GitHubError(status: 0, message: LS("账本已变化，请返回原账本重试")) }
        let existing = attachmentJobs()
        var jobs = existing.filter { $0.id != job.id }
        if !remove {
            // a job's bytes never change: written once, before the list that refers to them
            if !existing.contains(where: { $0.id == job.id }) {
                try RecoveryFiles.saveData(job.data, kind: Self.attachmentDataKind(job.id), ledger: cfg.id)
            }
            jobs.append(job)
        }
        try RecoveryFiles.save(jobs, kind: "attachments", ledger: cfg.id)
        if remove { try? RecoveryFiles.removeData(kind: Self.attachmentDataKind(job.id), ledger: cfg.id) }
        attachmentJobCache = (cfg.id, jobs)
        attachmentRevision += 1
    }

    func discardAttachmentJob(_ job: AttachmentUpload) {
        do { try saveAttachmentJob(job, remove: true) }
        catch { showFailure(LS("无法更新附件恢复记录：%@", error.localizedDescription)) }
    }

    /// Persist the confirmed path before starting the task. The sheet owns this job's identity.
    func prepareAttachment(_ data: Data, to t: Entry, ledgerID: String, path: String, account: String) throws -> AttachmentUpload {
        guard !attachmentUploading, !committing else {
            throw GitHubError(status: 0, message: LS("正在保存，请稍后重试"))
        }
        guard cfg.id == ledgerID, let L = L, EntryLocator(t).resolve(in: L.entries) != nil else {
            throw GitHubError(status: 0, message: LS("账本或交易已变化，请重新打开后添加附件"))
        }
        guard !account.isEmpty else { throw GitHubError(status: 0, message: LS("这笔交易没有付款账户，不能添加附件。")) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "documents", documentStoragePath(folder: parts[1], fileName: parts[2]) == path else {
            throw GitHubError(status: 0, message: LS("请填写文件名"))
        }
        if attachmentTakenPaths().contains(path) {
            throw GitHubError(status: 0, message: LS("这个文件已经在账本里，请改一个名字"))
        }
        let id = UUID()
        let rnd = String(id.uuidString.prefix(8)).lowercased()
        let link = t.links.first(where: { $0.hasPrefix("doc-") }) ?? "doc-\(t.date.replacingOccurrences(of: "-", with: ""))-\(rnd)"
        let ambiguous = L.entries.filter { $0.file == t.file && $0.type == .txn && normEntryText($0.src) == normEntryText(t.src) }.count > 1
        var sourceHash: String?
        if ambiguous {
            guard let version = tree?.files[t.file], let base = BlobCache.get(version) else {
                throw GitHubError(status: 0, message: LS("原交易已变化，请核对后重新添加附件"))
            }
            sourceHash = gitBlobSHA(try applyOps(base, path: t.file, ops: pending))
        }
        let job = AttachmentUpload(id: id, ledgerID: ledgerID, source: t.src, sourceStartLine: t.startLine, sourceFileHash: sourceHash, file: t.file, date: t.date, account: account, path: path, link: link, data: data)
        do { try saveAttachmentJob(job) }
        catch { throw GitHubError(status: 0, message: LS("无法保留附件，请稍后重试：%@", error.localizedDescription)) }
        return job
    }

    @discardableResult
    func retryAttachment(_ original: AttachmentUpload) async -> Bool {
        do {
            try await uploadAttachment(original)
            return true
        } catch is CancellationError {
            return false
        } catch {
            show(LS("附件未完成，恢复副本已保留：%@", error.localizedDescription))
            return false
        }
    }

    /// Throws the actual failure to the confirmation sheet; recovery rows use the toast wrapper above.
    func uploadAttachment(_ original: AttachmentUpload, destination: LedgerBackend? = nil) async throws {
        guard original.ledgerID == cfg.id else { throw GitHubError(status: 0, message: LS("账本已变化，请返回原账本重试")) }
        guard !attachmentUploading, !committing else { throw GitHubError(status: 0, message: LS("正在保存，请稍后重试")) }
        let ledgerID = cfg.id
        let destination = destination ?? backend
        guard var job = attachmentJobs().first(where: { $0.id == original.id && $0.ledgerID == ledgerID }) else {
            throw GitHubError(status: 0, message: LS("附件恢复任务已不存在，请重新打开后核对"))
        }
        attachmentUploading = true
        defer { attachmentUploading = false }
        do {
            try Task.checkCancellation()
            guard let entry = parseFile(job.source, file: job.file).entries.first(where: { $0.type == .txn }) else {
                throw GitHubError(status: 0, message: LS("原交易无法识别，附件已保留"))
            }
            let locator = EntryLocator(entry, startLine: job.sourceStartLine ?? -1)
            var linkedLines = job.source.components(separatedBy: "\n")
            if !entry.links.contains(job.link) { linkedLines[0] += " ^" + job.link }
            let linkedEntry = parseFile(linkedLines.joined(separator: "\n"), file: job.file).entries.first(where: { $0.type == .txn })
            func resolve(_ text: String) -> Entry? {
                let entries = parseFile(text, file: job.file).entries
                return linkedEntry.flatMap { EntryLocator($0, startLine: job.sourceStartLine ?? -1).resolve(in: entries) } ?? locator.resolve(in: entries)
            }
            let before = try await fileText(job.file)
            try Task.checkCancellation()
            guard cfg.id == ledgerID else { throw CancellationError() }
            guard let originalTarget = resolve(before) else {
                throw GitHubError(status: 0, message: LS("原交易已变化，请核对后重新添加附件"))
            }
            // A path alone does not identify this job's association.
            let samePath = L?.documents.filter { documentRepoPath($0) == job.path } ?? []
            if !samePath.isEmpty {
                guard originalTarget.links.contains(job.link), samePath.contains(where: {
                    $0.links.contains(job.link) && $0.account == job.account && $0.date == job.date
                }) else { throw GitHubError(status: 0, message: LS("这个文件已经在账本里，请改一个名字")) }
                try saveAttachmentJob(job, remove: true)
                return
            }
            // When identical transactions existed, any source-file change makes position ambiguous.
            guard job.sourceFileHash.map({ $0 == gitBlobSHA(before) }) ?? true else {
                throw GitHubError(status: 0, message: LS("原交易已变化，请核对后重新添加附件"))
            }
            guard !attachmentJobs().contains(where: { $0.id != job.id && $0.path == job.path }) else {
                throw GitHubError(status: 0, message: LS("这个文件已经在账本里，请改一个名字"))
            }
            if job.uploaded || job.uploadStarted == true || job.failure != nil {
                // A cancelled/failed response does not prove the server did not write.
                // A previously uploaded file may also have changed on another device.
                // Only a confirmed missing file permits another upload.
                do {
                    let remote = try await destination.readData(job.path)
                    try Task.checkCancellation()
                    guard cfg.id == ledgerID else { throw CancellationError() }
                    guard remote == job.data else {
                        throw GitHubError(status: 409, message: LS("这个文件已经在账本里，请改一个名字"))
                    }
                    job.uploaded = true
                    try saveAttachmentJob(job)
                } catch let error as GitHubError where error.status == 404 {
                    job.uploaded = false
                } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                    job.uploaded = false
                }
            }
            try Task.checkCancellation()
            guard cfg.id == ledgerID else { throw CancellationError() }
            if !job.uploaded {
                guard tree?.files[job.path] == nil else {
                    throw GitHubError(status: 0, message: LS("这个文件已经在账本里，请改一个名字"))
                }
                show(LS("正在上传附件…"))
                job.uploadStarted = true
                try saveAttachmentJob(job)
                try await destination.writeData(job.path, data: job.data, message: LS("附件：%@", job.path))
                guard cfg.id == ledgerID else { throw CancellationError() }
                // Record a completed write even when cancellation arrived during the request.
                job.uploaded = true
                try saveAttachmentJob(job)
                try Task.checkCancellation()
            }
            let current = try await fileText(job.file)
            try Task.checkCancellation()
            guard cfg.id == ledgerID, job.sourceFileHash.map({ $0 == gitBlobSHA(current) }) ?? true,
                  let target = resolve(current) else {
                throw GitHubError(status: 0, message: LS("原交易已变化，请核对后重新添加附件"))
            }
            let line = "\(job.date) document \(job.account) \"\(job.path)\" ^\(job.link)"
            guard let ledger = L else {
                throw GitHubError(status: 0, message: LS("原交易无法识别，附件已保留"))
            }
            var ops: [Op]
            let files = tree?.files ?? [:]
            switch LedgerKit.makeOps(line, ledger, layout: layout, pending: pending,
                                     fileExists: { files[$0] != nil }, extra: OpExtra(label: LS("附件：%@", job.path)), single: false) {
            case .success(let prepared): ops = prepared
            case .failure(let issue): throw GitHubError(status: 0, message: issue.message)
            }
            for i in ops.indices where ops[i].kind == .insert {
                ops[i].text = ops[i].text?.replacingOccurrences(of: "\"\(job.path)\"", with: "\"\(relativePath(job.path, from: ops[i].path))\"")
            }
            if !target.links.contains(job.link) {
                let lines = current.components(separatedBy: "\n")
                guard target.startLine < lines.count else {
                    throw GitHubError(status: 0, message: LS("原交易已变化，请核对后重新添加附件"))
                }
                var op = Op(kind: .link, path: job.file)
                op.headerLine = target.startLine + 1; op.header = lines[target.startLine]
                op.add = " ^" + job.link; op.link = job.link; op.silent = true
                ops.append(op)
            }
            guard await commit(ops, word: LS("已添加附件"), cancellable: true) else {
                try Task.checkCancellation()
                throw GitHubError(status: 0, message: LS("附件已上传，交易关联未完成，可重试"))
            }
            try saveAttachmentJob(job, remove: true)
        } catch {
            job.failure = Task.isCancelled ? LS("附件上传已取消，可在待处理附件中重试") : error.localizedDescription
            if cfg.id == ledgerID { try? saveAttachmentJob(job) }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

}

/// shrink a photo for the ledger repository
/// what can be attached, and what the app can show
let attachmentFormatsHint = "支持 JPG、PNG、HEIC、PDF 等常见格式；拍照和照片会转成 JPG。其他格式也能保存，但可能无法在 App 内预览。"

func jpegForUpload(_ image: UIImage) -> Data? {
    let maxSide: CGFloat = 2000
    let s = image.size
    let scale = min(1, maxSide / max(s.width, s.height))
    let size = CGSize(width: s.width * scale, height: s.height * scale)
    let r = UIGraphicsImageRenderer(size: size)
    let img = r.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    return img.jpegData(compressionQuality: 0.72)
}

struct AttachmentsSection: View {
    @Environment(Store.self) var store
    let t: Entry
    @State private var choosing = false
    @State private var photo: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var viewing: DocItem?
    @State private var owningLedgerID: String?
    @State private var pending: PendingAttachment?
    @State private var queuedFromCamera: PendingAttachment?

    var body: some View {
        let docs = store.documents(for: t)
        Section {
            ForEach(Array(docs.enumerated()), id: \.offset) { _, d in
                Button {
                    if let p = documentRepoPath(d) { viewing = DocItem(path: p) }
                } label: {
                    HStack(spacing: AppSpacing.icon) {
                        Image(systemName: icon(d.path ?? "")).foregroundStyle(Color.jadeInk)
                        Text(((d.path ?? "") as NSString).lastPathComponent).lineLimit(1)
                        Spacer()
                        Text(d.date).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
            AttachmentRecoveryRows(entry: t)
            Button { choosing = true } label: {
                Label(store.attachmentUploading ? LS("正在上传附件…") : LS("添加附件"), systemImage: "paperclip").labelStyle(ControlLabelStyle())
            }
            .disabled(store.attachmentUploading || store.committing)
            // presentations hang off this one row: on the Section they would be copied onto every row
            .confirmationDialog(LS("添加附件"), isPresented: $choosing) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) { Button { showCamera = true } label: { Text(LS("拍照")) } }
                Button { showPhotos = true } label: { Text(LS("从照片选择")) }
                Button { showFiles = true } label: { Text(LS("从文件选择")) }
            } message: {
                Text(LS(attachmentFormatsHint))
            }
            .photosPicker(isPresented: $showPhotos, selection: $photo, matching: .images)
            .onChange(of: photo) { _, item in
                guard let item = item else { return }
                Task {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d), let jpg = jpegForUpload(img) {
                        pending = PendingAttachment(data: jpg, ext: "jpg")
                    }
                    photo = nil
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .image, .data]) { result in
                guard case .success(let url) = result else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                guard let d = try? Data(contentsOf: url), !d.isEmpty else { return }
                let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension.lowercased()
                pending = PendingAttachment(data: d, ext: ext)
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { img in
                    showCamera = false
                    if let img = img, let jpg = jpegForUpload(img) { queuedFromCamera = PendingAttachment(data: jpg, ext: "jpg") }
                }
                .ignoresSafeArea()
            }
            .onChange(of: showCamera) { _, show in
                if !show, let queued = queuedFromCamera {
                    pending = queued
                    queuedFromCamera = nil
                }
            }
            .sheet(item: $pending) { item in
                AttachmentPathSheet(entry: t, data: item.data, ext: item.ext, ledgerID: owningLedgerID ?? "", existingPaths: store.attachmentTakenPaths())
            }
            .sheet(item: $viewing) { DocumentViewer(path: $0.path) }
        } header: {
            Text(LS("附件"))
        }
        .onAppear { if owningLedgerID == nil { owningLedgerID = store.cfg.id } }
    }

    private func icon(_ p: String) -> String {
        let e = (p as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(e) ? "photo" : e == "pdf" ? "doc.richtext" : "doc"
    }
}

struct PendingAttachment: Identifiable {
    let id = UUID()
    let data: Data
    let ext: String
}

/// After a photo or file is picked, confirm the folder and file name before anything is uploaded.
struct AttachmentPathSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: Entry
    let data: Data
    let ext: String
    let ledgerID: String
    let account: String
    @State private var folder: String
    @State private var fileStem: String
    @State private var stemEdited = false
    @State private var busy = false
    @State private var error: String?
    @State private var job: AttachmentUpload?
    @State private var saveTask: Task<Void, Never>?

    init(entry: Entry, data: Data, ext: String, ledgerID: String, existingPaths: Set<String>) {
        self.entry = entry
        self.data = data
        let normalizedExt = normalizedDocumentExtension(ext)
        self.ext = normalizedExt
        self.ledgerID = ledgerID
        let paying = documentPayingAccount(entry.postings)
        self.account = paying
        let suggested = transactionAttachmentFolder
        _folder = State(initialValue: suggested)
        _fileStem = State(initialValue: documentFileStem(
            preferredDocumentFileName(folder: suggested, date: entry.date, ext: normalizedExt, existingPaths: existingPaths), ext: normalizedExt))
    }

    private var takenPaths: Set<String> { store.attachmentTakenPaths(excluding: job?.id) }

    private var savedFileName: String { documentFileName(stem: fileStem, ext: ext) }

    private var pathIssue: String? {
        if account.isEmpty { return LS("这笔交易没有付款账户，不能添加附件。") }
        return documentLocationIssue(folder: folder, stem: fileStem, ext: ext, existing: takenPaths, isSaving: busy)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                    DocumentSaveToRow(
                        folder: $folder,
                        suggestedFolder: transactionAttachmentFolder,
                        folders: documentFolders(in: takenPaths),
                        onCommit: { refreshDefaultName() }
                    )
                    DocumentFileNameRow(fileStem: $fileStem, stemEdited: $stemEdited, fileExt: ext)
                    if let pathIssue { Text(pathIssue).foregroundStyle(Color.loss) }
                    if let error { Text(error).foregroundStyle(Color.loss) }
                } footer: {
                    if account.isEmpty {
                        Text(LS("这笔交易没有付款账户，不能添加附件。"))
                    } else {
                        Text(LS("文件会记在付款账户 %@ 上。转账记在转出的一方。右上角「保存」才上传。键盘回车「完成」和「收起键盘」只收起键盘。", acctDisplay(account)))
                    }
                }
            }
            .disabled(busy)
            .documentKeyboardDismiss()
            .navigationTitle(LS("确认附件"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { cancel() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: {
                        BusyLabel(busy: busy, title: LS("保存"), systemImage: "checkmark")
                    }
                    .disabled(busy || pathIssue != nil)
                    .accessibilityIdentifier("attachment.save")
                }
            }
            .interactiveDismissDisabled(busy)
            .onAppear { refreshDefaultName() }
            .onChange(of: store.tree?.sha) { _, _ in refreshDefaultName() }
            .onChange(of: store.cfg.id) { _, _ in cancel() }
            .onDisappear { saveTask?.cancel() }
        }
    }

    private func refreshDefaultName() {
        guard !stemEdited, !busy, job == nil else { return }
        let full = preferredDocumentFileName(folder: folder, date: entry.date, ext: ext, existingPaths: takenPaths)
        fileStem = documentFileStem(full, ext: ext)
    }

    private func cancel() {
        saveTask?.cancel()
        dismiss()
    }

    private func save() {
        guard !busy, pathIssue == nil, let path = documentStoragePath(folder: folder, fileName: savedFileName) else { return }
        error = nil
        do {
            // Only this sheet's own job may be retried without a duplicate-name check.
            let confirmed: AttachmentUpload
            if let job, job.path == path {
                confirmed = store.attachmentJobs().first(where: { $0.id == job.id }) ?? job
            } else {
                confirmed = try store.prepareAttachment(data, to: entry, ledgerID: ledgerID, path: path, account: account)
            }
            job = confirmed
            busy = true
            saveTask = Task { @MainActor in
                // Success stays busy through dismissal; only failure resumes live validation.
                defer { saveTask = nil }
                do {
                    try await store.uploadAttachment(confirmed)
                    if !Task.isCancelled { dismiss() }
                } catch is CancellationError {
                    busy = false
                    return
                } catch {
                    busy = false
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

}

struct DocItem: Identifiable { let path: String; var id: String { path } }

struct TransactionAttachmentsDest: Hashable {}

/// 交易附件: every transaction's attachments in one list, whichever account paid; account pages keep their statements
struct TransactionAttachmentsView: View {
    @Environment(Store.self) var store
    @State private var viewing: DocItem?
    /// 最近删除 being restored
    @State private var recovering: UUID?

    var body: some View {
        Group {
            if let L = store.L { list(L) } else { PageLoading() }
        }
        .navigationTitle(LS("交易附件"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $viewing) { DocumentViewer(path: $0.path) }
    }

    private func list(_ L: Ledger) -> some View {
        let docs = transactionAttachments(L)
        // each attachment's transaction, by link
        var byLink: [String: Entry] = [:]
        for t in L.txns where !t.synthetic { for l in t.links where byLink[l] == nil { byLink[l] = t } }
        return List {
            Section {
                if docs.isEmpty { Text(LS("还没有交易附件")).foregroundStyle(.secondary) }
                ForEach(docs, id: \.id) { d in
                    let txn = d.links.lazy.compactMap { byLink[$0] }.first
                    Button {
                        if let path = documentRepoPath(d) { viewing = DocItem(path: path) }
                    } label: {
                        HStack(spacing: AppSpacing.icon) {
                            Image(systemName: "paperclip").foregroundStyle(Color.jadeInk)
                            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                Text(((d.path ?? "") as NSString).lastPathComponent).lineLimit(1)
                                Text([d.date, txn.map { [$0.payee, $0.narration].filter { !$0.isEmpty }.joined(separator: " · ") } ?? ""]
                                    .filter { !$0.isEmpty }.joined(separator: "  "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(documentRepoPath(d) == nil)
                    .entryActions(d)
                }
            } footer: {
                Text(LS("在交易详情里添加的附件，默认存放在 documents/%@ 文件夹；账户的对账单仍在各账户页。", transactionAttachmentFolder))
            }
            recentlyDeleted()
        }
    }

    /// files deleted with their record (attachments and statements alike), each with 恢复 while its copy is kept
    @ViewBuilder
    private func recentlyDeleted() -> some View {
        let items = store.deletedAttachments().sorted { $0.time > $1.time }
        if !items.isEmpty {
            Section {
                ForEach(items) { d in
                    HStack(spacing: AppSpacing.icon) {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: AppSpacing.detail) {
                            Text((d.path as NSString).lastPathComponent).lineLimit(1)
                            Text(d.state == .deleted
                                 ? LS("删除于 %@ · 剩 %@ 天", Day.string(d.time), d.daysLeft(now: Date()))
                                 : LS("同步后删除文件"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            recovering = d.id
                            Task { _ = await store.recoverDeletedAttachment(d.id); recovering = nil }
                        } label: {
                            if recovering == d.id { ProgressView() } else { Text(LS("恢复")) }
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        .disabled(recovering != nil || store.committing)
                    }
                }
            } header: {
                Text(LS("最近删除"))
            } footer: {
                Text(LS("选「移除并删除文件」删掉的附件和对账单在这里保留 %@ 天，点「恢复」会把文件传回存储并恢复记录。", Int(DeletedAttachment.keep / 86_400)))
            }
        }
    }
}

/// downloads a file from the ledger storage and shows it with Quick Look
struct DocumentViewer: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var url: URL?
    @State private var error: String?
    @State private var retry = 0
    @State private var temporaryFolder: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let u = url { QuickLookView(url: u) }
                else if let e = error {
                    VStack(spacing: AppSpacing.content) {
                        Text(e).foregroundStyle(.secondary)
                        Button { retry += 1 } label: { Label(LS("重试"), systemImage: "arrow.clockwise").labelStyle(ControlLabelStyle()) }
                    }.padding(AppSpacing.content)
                }
                else { PageLoading() }
            }
            .navigationTitle((path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) } }
                if let u = url { ToolbarItem(placement: .topBarLeading) { ShareLink(item: u) } }
            }
        }
        .task(id: retry) {
            error = nil
            do {
                let d = try await store.backend.readData(path)
                try Task.checkCancellation()
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-document-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                temporaryFolder = dir
                let f = dir.appendingPathComponent((path as NSString).lastPathComponent)
                try d.write(to: f, options: .atomic)
                url = f
            } catch is CancellationError {
                return
            } catch {
                self.error = LS("无法下载：%@", error.localizedDescription)
            }
        }
        .onChange(of: store.cfg.id) { _, _ in dismiss() }
        .onDisappear {
            if let dir = temporaryFolder { try? FileManager.default.removeItem(at: dir) }
        }
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }
    func updateUIViewController(_ c: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
