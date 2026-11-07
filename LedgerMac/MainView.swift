import SwiftUI
import LedgerKit

enum Page: CaseIterable {
    case journal, accounts, reports

    var title: String {
        switch self {
        case .journal: return chinese ? "明细" : "Journal"
        case .accounts: return chinese ? "账户" : "Accounts"
        case .reports: return chinese ? "报表" : "Reports"
        }
    }

    var symbol: String {
        switch self {
        case .journal: return "list.bullet"
        case .accounts: return "building.columns"
        case .reports: return "chart.bar"
        }
    }
}

/// the journal kept to what a report counted for one account
struct JournalScope {
    let title: String
    let account: String
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
    @State private var scope: JournalScope?
    @State private var period = ReportPeriod.thisMonth
    @State private var git: FolderGitStatus?
    @State private var gitReads = 0
    @State private var syncing = false
    @State private var pulling = false
    @State private var pullError: String?
    /// false before the first check and after one that failed: without an answer, Pull stays there to try
    @State private var remoteReached = false
    @State private var checkingRemote = false

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, id: \.self, selection: $page) { item in
                Label(item.title, systemImage: item.symbol)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160)
        } detail: {
            Group {
                switch page ?? .journal {
                case .journal: JournalPage(ledger: ledger, config: config, folder: folder, scope: $scope, searching: $searching)
                case .accounts:
                    AccountsPage(ledger: ledger, config: config, folder: folder) { open($0, title: accountTitle(ledger, $0), span: nil) }
                case .reports:
                    ReportsPage(ledger: ledger, period: $period) { open($0, title: accountTitle(ledger, $0) + " · " + period.title, span: period.span) }
                }
            }
            .safeAreaInset(edge: .bottom) { ErrorBar(errors: ledger.errors.filter { !$0.soft }) }
            .toolbar {
                if let git {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { pull() } label: {
                            if pulling {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(chinese ? "拉取" : "Pull", systemImage: git.behind > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                                    .foregroundStyle(git.behind > 0 ? Color.accentColor : Color.primary)
                            }
                        }
                        .disabled(pulling || (remoteReached && git.behind == 0))
                        Button { syncing = true } label: { Label(chinese ? "提交并推送" : "Commit and Push", systemImage: "arrow.up.circle") }
                            .disabled(!git.canSync)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label(chinese ? "记一笔" : "New Entry", systemImage: "plus") }
                }
            }
        }
        .sheet(isPresented: $adding) {
            NewEntrySheet(ledger: ledger, config: config, folder: folder)
        }
        .sheet(isPresented: $syncing) {
            if let git { SyncSheet(folder: folder, status: git) { gitReads += 1 } }
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
        .alert(pullError ?? "", isPresented: Binding(get: { pullError != nil }, set: { if !$0 { pullError = nil } })) {}
        .onChange(of: page) { if page != .journal { scope = nil } }
    }

    private func open(_ account: String, title: String, span: (String, String)?) {
        scope = JournalScope(title: title, account: account, from: span?.0, to: span?.1)
        page = .journal
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

    private func pull() {
        pulling = true
        let folder = folder
        Task { @MainActor in
            let result = await Task.detached { Result { try pullFolderGit(folder) } }.value
            pulling = false
            gitReads += 1
            if case .failure(let error) = result { pullError = error.localizedDescription }
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
