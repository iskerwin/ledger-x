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

/// Used both next to a transaction and in ledger sync, so changed/deleted transactions do not hide recovery.
struct AttachmentRecoveryRows: View {
    @EnvironmentObject private var store: Store
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
