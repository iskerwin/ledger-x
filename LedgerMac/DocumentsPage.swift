import SwiftUI
import Quartz
import UniformTypeIdentifiers
import LedgerKit

/// which documents the page lists
private enum DocumentKind: String, CaseIterable {
    case all = "全部", attachments = "交易附件", statements = "对账单"

    func holds(_ item: DocumentItem) -> Bool {
        switch self {
        case .all: return true
        case .attachments: return item.isAttachment
        case .statements: return !item.isAttachment
        }
    }
}

/// 附件与对账单, as Fava's documents page: the accounts with how many each has on the left, their files on a table, and
/// the one picked shown under it. A file dropped on an account is kept with it as a statement
struct DocumentsPage: View {
    let ledger: Ledger
    let folder: URL
    @State private var account: String?
    @State private var kind = DocumentKind.all
    @State private var query = ""
    @State private var picked: DocumentItem.ID?
    @State private var message = ""

    var body: some View {
        let all = documentItems(ledger)
        let counts = Dictionary(grouping: all, by: \.account).mapValues(\.count)
        let shown = all.filter { (account.map { a in $0.account == a } ?? true) && kind.holds($0) && documentMatches($0, query, ledger) }
        HStack(spacing: 0) {
            accounts(all.count, counts)
                .frame(width: 260)
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Picker(selection: $kind) {
                        ForEach(DocumentKind.allCases, id: \.self) { Text($0.rawValue) }
                    } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    TextField("搜索", text: $query, prompt: Text("文件名、收付款方、账户"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Spacer()
                    Button("添加对账单…", systemImage: "doc.badge.plus") { choose() }
                        .disabled(account == nil)
                        .help(account == nil ? "先在左边选一个账户" : "")
                }
                .padding(12)
                if !message.isEmpty {
                    Text(message).foregroundStyle(Color.loss).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
                }
                Table(shown, selection: $picked) {
                    TableColumn("日期") { Text($0.entry.date).monospacedDigit() }.width(min: 80, ideal: 90, max: 110)
                    TableColumn("文件") { item in
                        Label(item.name, systemImage: item.isAttachment ? "paperclip" : "doc.text").lineLimit(1)
                    }
                    TableColumn("交易 / 账户") { item in
                        if let t = item.transaction {
                            Text([t.payee, t.narration].filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1)
                        } else {
                            Text(accountTitle(ledger, item.account)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let account else { return false }
                    keep(urls, with: account)
                    return true
                }
                if let item = shown.first(where: { $0.id == picked }) {
                    Divider()
                    DocumentPreview(item: item, ledger: ledger, folder: folder)
                        .frame(height: 320)
                }
            }
        }
        .background(Color.page)
        .onChange(of: shown.map(\.id)) { if let picked, !shown.contains(where: { $0.id == picked }) { self.picked = nil } }
    }

    /// 全部, then each account that has documents, under 资产, 负债 and the rest
    private func accounts(_ total: Int, _ counts: [String: Int]) -> some View {
        let roots = [("资产", "Assets"), ("负债", "Liabilities")]
        let named = counts.keys.sorted()
        let rest = named.filter { a in !roots.contains { a.hasPrefix($0.1 + ":") } }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                PickRow(title: "全部", trailing: "\(total)", picked: account == nil) { account = nil }
                ForEach(roots + [("其他", "")], id: \.0) { group in
                    let names = group.1.isEmpty ? rest : named.filter { $0.hasPrefix(group.1 + ":") }
                    if !names.isEmpty {
                        Text(group.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
                        ForEach(names, id: \.self) { name in
                            PickRow(title: accountTitle(ledger, name), trailing: "\(counts[name] ?? 0)", picked: account == name) { account = name }
                                .dropDestination(for: URL.self) { urls, _ in
                                    keep(urls, with: name)
                                    return true
                                }
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private func choose() {
        guard let account else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        keep(panel.urls, with: account)
    }

    /// each file kept with the account as a statement, on the writing path; the folder's watcher reads them back
    private func keep(_ urls: [URL], with account: String) {
        let folder = folder
        Task {
            let failed = await Task.detached { DocumentFiles.keep(urls, with: account, folder: folder) }.value
            message = failed ?? ""
        }
    }
}

/// adding files from this Mac, the way the phone does
enum DocumentFiles {
    /// each file as a statement of `account`, dated by its name when it has a day in it (2026-10-31, 20261031), else today;
    /// the first failure, else nil
    static func keep(_ urls: [URL], with account: String, folder: URL) -> String? {
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { return "读不了 \(url.lastPathComponent)" }
            let prepared = prepareFolderStatement(account: account, date: documentDay(inName: url.lastPathComponent) ?? Day.today(), data: data,
                                                  ext: url.pathExtension, folder: folder)
            if let failure = commit(prepared, folder: folder) { return failure }
        }
        return nil
    }

    /// each file attached to `entry`; the first failure, else nil
    static func attach(_ urls: [URL], to entry: Entry, folder: URL) -> String? {
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { return "读不了 \(url.lastPathComponent)" }
            if let failure = commit(prepareFolderAttachment(entry, data: data, ext: url.pathExtension, folder: folder), folder: folder) { return failure }
        }
        return nil
    }

    private static func commit(_ prepared: Result<FolderSave, FolderSaveError>, folder: URL) -> String? {
        switch prepared {
        case .failure(let error): return error.message
        case .success(let save):
            if let issue = save.issues.first { return issue.detail.isEmpty ? issue.title : issue.detail }
            do { try commitFolderSave(save, folder: folder) } catch { return error.localizedDescription }
            return nil
        }
    }
}

/// the file picked, as Quick Look shows it, with where it goes from here
private struct DocumentPreview: View {
    let item: DocumentItem
    let ledger: Ledger
    let folder: URL

    var body: some View {
        let url = item.path.map { folder.appendingPathComponent($0) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.path ?? item.entry.path ?? "").font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let link = item.entry.links.first, item.transaction != nil {
                    NavigationLink("到明细", value: JournalScope(title: item.name, link: link))
                }
                Button("打开") { if let url { NSWorkspace.shared.open(url) } }.disabled(url == nil)
                Button("在 Finder 中显示") { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }.disabled(url == nil)
            }
            if let url, FileManager.default.fileExists(atPath: url.path) {
                QuickLook(url: url)
            } else {
                ContentUnavailableView("找不到这个文件", systemImage: "doc.questionmark")
            }
        }
        .padding(12)
    }
}

private struct QuickLook: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.autostarts = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url { view.previewItem = url as NSURL }
    }
}
