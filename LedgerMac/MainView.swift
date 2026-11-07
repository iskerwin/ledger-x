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
    @Binding var adding: Bool
    @State private var page: Page? = .journal
    @State private var scope: JournalScope?
    @State private var period = ReportPeriod.thisMonth

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, id: \.self, selection: $page) { item in
                Label(item.title, systemImage: item.symbol)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160)
        } detail: {
            Group {
                switch page ?? .journal {
                case .journal: JournalPage(ledger: ledger, config: config, folder: folder, scope: $scope)
                case .accounts:
                    AccountsPage(ledger: ledger, config: config) { open($0, title: accountTitle(ledger, $0), span: nil) }
                case .reports:
                    ReportsPage(ledger: ledger, period: $period) { open($0, title: accountTitle(ledger, $0) + " · " + period.title, span: period.span) }
                }
            }
            .safeAreaInset(edge: .bottom) { ErrorBar(errors: ledger.errors.filter { !$0.soft }) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label(chinese ? "记一笔" : "New Entry", systemImage: "plus") }
                }
            }
        }
        .sheet(isPresented: $adding) {
            NewEntrySheet(ledger: ledger, config: config, folder: folder)
        }
        .onChange(of: page) { if page != .journal { scope = nil } }
    }

    private func open(_ account: String, title: String, span: (String, String)?) {
        scope = JournalScope(title: title, account: account, from: span?.0, to: span?.1)
        page = .journal
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
