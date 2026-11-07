import SwiftUI
import LedgerKit

enum Page: String, CaseIterable {
    case journal, accounts, reports, sync

    var title: String {
        switch self {
        case .journal: return "明细"
        case .accounts: return "账户"
        case .reports: return "报表"
        case .sync: return "同步与改动"
        }
    }

    var symbol: String {
        switch self {
        case .journal: return "list.bullet"
        case .accounts: return "building.columns"
        case .reports: return "chart.bar"
        case .sync: return "arrow.up.arrow.down"
        }
    }
}

/// the journal kept to what a report counted for one account
struct JournalScope: Hashable {
    let title: String
    var account: String?
    var from: String?
    var to: String?

    func matches(_ entry: Entry) -> Bool { entryCounts(entry, for: account, from: from, to: to) }
}

struct MainView: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    /// counts the changes seen in the folder's files
    let changes: Int
    @Binding var adding: Bool
    @Binding var page: Page?
    @Binding var searching: Bool
    @Binding var picking: Bool
    /// showing the entries a row counts, where the search box has them to search
    @State private var inScope = false
    @State private var git: FolderGitStatus?
    @State private var gitReads = 0
    /// false before the first check and after one that failed: without an answer, 拉取 stays there to try
    @State private var remoteReached = false
    @State private var checkingRemote = false

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("账本") {
                    row(.journal)
                    row(.accounts)
                }
                Section("分析") {
                    row(.reports)
                }
                if let git {
                    Section("同步") {
                        row(.sync).badge(git.paths.count + git.ahead + git.behind)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsLink { Label("设置", systemImage: "gearshape") }
                    Button { picking = true } label: { Label("切换账本…", systemImage: "folder") }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 208, max: 260)
        } detail: {
            Group {
                switch page ?? .journal {
                case .journal: JournalPage(ledger: ledger, config: config, folder: folder, scope: nil, searching: $searching)
                case .accounts:
                    drillable { AccountsPage(ledger: ledger, config: config, folder: folder) { JournalScope(title: accountTitle(ledger, $0), account: $0) } }
                case .reports:
                    drillable { ReportsPage(ledger: ledger, config: config) }
                case .sync:
                    SyncPage(folder: folder, status: git, remoteReached: remoteReached) { gitReads += 1 }
                }
            }
            // a list of its own for each page: left to reuse its rows, one page's row keeps what the last page's row did when clicked
            .id(page ?? .journal)
            .safeAreaInset(edge: .bottom) { ErrorBar(errors: ledger.errors.filter { !$0.soft }) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("记一笔", systemImage: "plus") }
                        .help("记一笔")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NewEntrySheet(ledger: ledger, config: config, folder: folder)
        }
        .task(id: "\(changes)|\(gitReads)|\(folder.path)") {
            let folder = folder
            let status = await Task.detached { folderGitStatus(folder) }.value
            guard !Task.isCancelled else { return }
            git = status
        }
        .task(id: folder.path) { checkRemote() }
        // what happens in .git isn't watched: a commit made in a terminal, or on another device, is seen on coming back
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in checkRemote() }
        .onChange(of: searching) {
            guard searching, !inScope, page != .journal else { return }
            page = .journal
            // the box takes focus only when it opens with the page already there
            searching = false
            DispatchQueue.main.async { searching = true }
        }
    }

    private func row(_ item: Page) -> some View {
        Label(item.title, systemImage: item.symbol).tag(item)
    }

    /// a row of the page opens the entries it counts, a level down; the journal is all entries already, and its search box needs no stack around it
    private func drillable(@ViewBuilder _ page: () -> some View) -> some View {
        NavigationStack {
            page().navigationDestination(for: JournalScope.self) { scope in
                JournalPage(ledger: ledger, config: config, folder: folder, scope: scope, searching: $searching)
                    .navigationTitle(scope.title)
                    .onAppear { inScope = true }
                    .onDisappear { inScope = false }
            }
        }
    }

    private func checkRemote() {
        guard !checkingRemote else { return }
        checkingRemote = true
        let folder = folder
        Task { @MainActor in
            remoteReached = await Task.detached { folderGitStatus(folder) != nil && fetchFolderGit(folder) }.value
            checkingRemote = false
            gitReads += 1
        }
    }
}

/// a ledger that didn't read cleanly can be missing entries, so this stays in sight
private struct ErrorBar: View {
    let errors: [LedgerError]

    var body: some View {
        if let first = errors.first {
            Text(errors.count > 1 ? "\(first.msg) (+\(errors.count - 1))" : first.msg)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(first.msg)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
    }
}
