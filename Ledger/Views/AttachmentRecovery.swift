import SwiftUI
import LedgerKit

struct AttachmentUpload: Codable, Identifiable {
    var id: UUID
    var ledgerID: String
    var source: String
    var sourceStartLine: Int?
    var sourceFileHash: String?
    var file: String
    var date: String
    var account: String
    var path: String
    var link: String
    var data: Data
    var uploadStarted: Bool?
    var uploaded = false
    var failure: String?
}

/// The bytes are not part of the saved list: they go to a file of their own (see Store.attachmentJobs), so the list
/// stays a few KB to read and write. A list saved before that still has them inline and is read as before.
extension AttachmentUpload {
    enum CodingKeys: String, CodingKey {
        case id, ledgerID, source, sourceStartLine, sourceFileHash, file, date, account, path, link, data, uploadStarted, uploaded, failure
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        ledgerID = try c.decode(String.self, forKey: .ledgerID)
        source = try c.decode(String.self, forKey: .source)
        sourceStartLine = try c.decodeIfPresent(Int.self, forKey: .sourceStartLine)
        sourceFileHash = try c.decodeIfPresent(String.self, forKey: .sourceFileHash)
        file = try c.decode(String.self, forKey: .file)
        date = try c.decode(String.self, forKey: .date)
        account = try c.decode(String.self, forKey: .account)
        path = try c.decode(String.self, forKey: .path)
        link = try c.decode(String.self, forKey: .link)
        data = try c.decodeIfPresent(Data.self, forKey: .data) ?? Data()
        uploadStarted = try c.decodeIfPresent(Bool.self, forKey: .uploadStarted)
        uploaded = try c.decodeIfPresent(Bool.self, forKey: .uploaded) ?? false
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(ledgerID, forKey: .ledgerID)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(sourceStartLine, forKey: .sourceStartLine)
        try c.encodeIfPresent(sourceFileHash, forKey: .sourceFileHash)
        try c.encode(file, forKey: .file)
        try c.encode(date, forKey: .date)
        try c.encode(account, forKey: .account)
        try c.encode(path, forKey: .path)
        try c.encode(link, forKey: .link)
        try c.encodeIfPresent(uploadStarted, forKey: .uploadStarted)
        try c.encode(uploaded, forKey: .uploaded)
        try c.encodeIfPresent(failure, forKey: .failure)
    }
}

/// Used both next to a transaction and in ledger sync, so changed/deleted transactions do not hide recovery.
struct AttachmentRecoveryRows: View {
    @Environment(Store.self) private var store
    var entry: Entry? = nil
    @State private var jobs: [AttachmentUpload] = []
    @State private var discarding: AttachmentUpload?
    private var scope: String { store.cfg.id + String(store.attachmentRevision) }
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.icon) {
            if !jobs.isEmpty { Text(LS("待处理附件")).font(.caption).foregroundStyle(.secondary) }
            ForEach(jobs) { job in
                VStack(alignment: .leading, spacing: AppSpacing.icon) {
                    Text((job.path as NSString).lastPathComponent).font(.subheadline).lineLimit(2)
                    Text(job.failure ?? LS("附件尚未完成，副本保存在本机")).font(.caption).foregroundStyle(.secondary)
                    ActionRow(size: .small, items: [
                        ActionRow.Item(title: LS("重试"), systemImage: "arrow.clockwise", emphasis: .primary) {
                            Task { await store.retryAttachment(job) }
                        },
                        ActionRow.Item(title: LS("移除本机恢复副本"), systemImage: "trash", emphasis: .destructive) {
                            discarding = job
                        },
                    ])
                    .disabled(store.attachmentUploading || store.committing)
                }
            }
        }
        .task(id: scope) {
            jobs = store.attachmentJobs().filter { job in
                guard let entry = entry else { return true }
                return entry.links.contains(job.link) || entry.file == job.file && normEntryText(entry.src) == normEntryText(job.source)
            }
        }
        .confirmationDialog(LS("移除本机恢复副本？"), isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }), titleVisibility: .visible) {
            Button(role: .destructive) {
                if let job = discarding { store.discardAttachmentJob(job) }
                discarding = nil
            } label: { Text(LS("移除本机恢复副本")) }
            Button(role: .cancel) { discarding = nil } label: { Text(LS("取消")) }
        } message: {
            Text(LS("只移除本机的重试副本，原始文件与已经上传的文件保留。"))
        }
    }
}
