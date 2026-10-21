import SwiftUI
import UIKit
import LedgerKit

/// backups to a Files folder, and exports to share
struct BackupView: View {
    @EnvironmentObject var store: Store
    @AppStorage(Backup.autoKey) private var auto = true
    @State private var picking = false
    @State private var busy = false
    @State private var folder = Backup.folderName
    @State private var zip: URL?
    @State private var range = "year"
    @State private var tick = 0

    var body: some View {
        List {
            Section {
                Button { picking = true } label: {
                    HStack(spacing: AppSpacing.control) {
                        Label(folder ?? LS("选择备份文件夹"), systemImage: "folder").labelStyle(ControlLabelStyle())
                        Spacer()
                        if folder != nil { Text(LS("更换")).foregroundStyle(.secondary) }
                    }
                }
                Toggle(LS("每周自动备份"), isOn: $auto).disabled(folder == nil)
                Button {
                    Task { busy = true; await Backup.run(store); busy = false; tick += 1 }
                } label: {
                    HStack(spacing: AppSpacing.control) { Label(LS("立即备份"), systemImage: "externaldrive.badge.checkmark").labelStyle(ControlLabelStyle()); if busy { Spacer(); ProgressView() } }
                }
                .disabled(folder == nil || busy)
                if let d = Backup.last(store) {
                    LabeledContent(LS("上次备份"), value: d.formatted(date: .abbreviated, time: .shortened)).id(tick)
                }
            } header: {
                Text(LS("自动备份"))
            } footer: {
                Text(LS("把整个账本（包括还没同步的修改）打包成 zip，存到你选的文件夹，例如 iCloud Drive 里新建的「Ledger X 备份」。打开 App 时如果距上次备份超过 7 天会自动备份，每个账本保留最近 %@ 份。票据附件不包含在内。", Backup.keep))
            }

            Section {
                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        do { zip = try await Backup.makeZip(store) } catch { store.show(LS("备份失败：%@", error.localizedDescription)) }
                    }
                } label: { Label(LS("分享账本压缩包"), systemImage: "doc.zipper").labelStyle(ControlLabelStyle()) }
                .disabled(busy)
                Picker(LS("交易明细范围"), selection: $range) {
                    Text(LS("今年")).tag("year")
                    Text(LS("去年")).tag("last")
                    Text(LS("全部")).tag("all")
                }
                if let L = store.L {
                    let (from, to, name) = span()
                    ShareLink(item: CSVFile(name: name, text: exportCSV(L, from: from, to: to)), preview: SharePreview(name + ".csv")) {
                        Label(LS("导出交易明细（CSV）"), systemImage: "tablecells").labelStyle(ControlLabelStyle())
                    }
                }
            } header: {
                Text(LS("导出"))
            } footer: {
                Text(LS("CSV 每行一条分录，含日期、收付款方、摘要、科目、金额、币种、标签和链接，可用 Excel 或 Numbers 打开。"))
            }
        }
        .navigationTitle(LS("备份与导出"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Backup.setFolder(url)
            folder = Backup.folderName
        }
        .sheet(item: Binding(get: { zip.map { ZipItem(url: $0) } }, set: { if $0 == nil { zip = nil } })) { z in
            ShareSheet(items: [z.url])
        }
    }

    private func span() -> (String, String, String) {
        let y = Int(Day.today().prefix(4)) ?? 2026
        switch range {
        case "year": return ("\(y)-01-01", "\(y)-12-31", LS("交易明细 %@", String(y)))
        case "last": return ("\(y - 1)-01-01", "\(y - 1)-12-31", LS("交易明细 %@", String(y - 1)))
        default: return ("", "", LS("交易明细 全部"))
        }
    }
}

private struct ZipItem: Identifiable { let url: URL; var id: String { url.path } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
