import SwiftUI
import LedgerKit

private enum Page: CaseIterable {
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

struct MainView: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    /// counts the changes seen in the folder's files
    let changes: Int
    @Binding var adding: Bool
    @State private var page: Page? = .journal
    @State private var git: FolderGitStatus?
    @State private var gitReads = 0
    @State private var syncing = false

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, id: \.self, selection: $page) { item in
                Label(item.title, systemImage: item.symbol)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160)
        } detail: {
            Group {
                switch page ?? .journal {
                case .journal: JournalPage(ledger: ledger, config: config, folder: folder)
                case .accounts: AccountsPage(ledger: ledger, config: config)
                case .reports: ReportsPage(ledger: ledger)
                }
            }
            .safeAreaInset(edge: .bottom) { ErrorBar(errors: ledger.errors.filter { !$0.soft }) }
            .toolbar {
                if let git {
                    ToolbarItem(placement: .primaryAction) {
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
        // what happens in .git isn't watched: a commit made in a terminal is seen on coming back
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in gitReads += 1 }
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
