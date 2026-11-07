import SwiftUI
import LedgerKit

enum Page: CaseIterable {
    case journal, accounts, reports, months

    var title: String {
        switch self {
        case .journal: return "明细"
        case .accounts: return "账户"
        case .reports: return "报表"
        case .months: return "按月"
        }
    }

    var symbol: String {
        switch self {
        case .journal: return "list.bullet"
        case .accounts: return "building.columns"
        case .reports: return "chart.bar"
        case .months: return "calendar"
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
    /// showing the entries a row counts, where the search box has them to search
    @State private var inScope = false
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
            NavigationStack {
                Group {
                    switch page ?? .journal {
                    case .journal: JournalPage(ledger: ledger, config: config, folder: folder, scope: nil, searching: $searching)
                    case .accounts:
                        AccountsPage(ledger: ledger, config: config, folder: folder) { JournalScope(title: accountTitle(ledger, $0), account: $0) }
                    case .reports:
                        ReportsPage(ledger: ledger, period: $period)
                    case .months:
                        MonthsPage(ledger: ledger) { JournalScope(title: $0, from: Day.ym($0) + "-01", to: Day.monthEnd($0)) }
                    }
                }
                .navigationDestination(for: JournalScope.self) { scope in
                    JournalPage(ledger: ledger, config: config, folder: folder, scope: scope, searching: $searching)
                        .navigationTitle(scope.title)
                        .onAppear { inScope = true }
                        .onDisappear { inScope = false }
                }
            }
            // a list of its own for each page: left to reuse its rows, one page's row keeps what the last page's row did when clicked
            .id(page ?? .journal)
            .safeAreaInset(edge: .bottom) { ErrorBar(errors: ledger.errors.filter { !$0.soft }) }
            .toolbar {
                if let git {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { pull() } label: {
                            if pulling {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("拉取", systemImage: git.behind > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                                    .foregroundStyle(git.behind > 0 ? Color.accentColor : Color.primary)
                            }
                        }
                        .disabled(pulling || (remoteReached && git.behind == 0))
                        .help("拉取")
                        Button { syncing = true } label: { Label("提交并推送", systemImage: "arrow.up.circle") }
                            .disabled(!git.canSync)
                            .help("提交并推送")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("记一笔", systemImage: "plus") }
                        .help("记一笔")
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
        .onChange(of: searching) { if searching && !inScope { page = .journal } }
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
