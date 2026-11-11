import SwiftUI
import LedgerKit

enum Page: String, CaseIterable {
    case overview, journal, accounts
    case reports, payees, year
    case budgets, forecast, subscriptions
    case reimbursements, salary, events
    case query, errors, sync

    var title: String {
        switch self {
        case .overview: return "概览"
        case .journal: return "明细"
        case .accounts: return "账户"
        case .reports: return "报表"
        case .payees: return "收付款方"
        case .year: return "年度回顾"
        case .budgets: return "预算"
        case .forecast: return "现金流预测"
        case .subscriptions: return "订阅"
        case .reimbursements: return "报销"
        case .salary: return "工资"
        case .events: return "事件"
        case .query: return "BQL 查询"
        case .errors: return "错误"
        case .sync: return "同步与改动"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .journal: return "list.bullet"
        case .accounts: return "building.columns"
        case .reports: return "chart.bar"
        case .payees: return "person.2"
        case .year: return "calendar"
        case .budgets: return "chart.pie"
        case .forecast: return "chart.line.uptrend.xyaxis"
        case .subscriptions: return "repeat"
        case .reimbursements: return "list.bullet.rectangle"
        case .salary: return "banknote"
        case .events: return "star"
        case .query: return "terminal"
        case .errors: return "exclamationmark.triangle"
        case .sync: return "arrow.up.arrow.down"
        }
    }

    /// looks at the window's time
    var followsPeriod: Bool { [.overview, .journal, .reports, .year, .budgets].contains(self) }

    /// the sidebar's groups, in order; the menu follows them
    static let sections: [(String, [Page])] = [
        ("账本", [.overview, .journal, .accounts]),
        ("分析", [.reports, .payees, .year]),
        ("计划", [.budgets, .forecast, .subscriptions]),
        ("往来", [.reimbursements, .salary, .events]),
        ("工具", [.query, .errors, .sync]),
    ]
}

/// the journal kept to what a report counted for one account
struct JournalScope: Hashable {
    let title: String
    var account: String?
    var from: String?
    var to: String?
    /// the entries sharing a link: a reimbursement's batch
    var link: String?

    func matches(_ entry: Entry) -> Bool {
        (link.map { entry.links.contains($0) } ?? true) && entryCounts(entry, for: account, from: from, to: to)
    }
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
    @State private var alerts: [Anomaly] = []
    /// the time the pages look at, kept as they change, as Fava's filter
    @State private var period = ViewPeriod()
    /// the account the journal keeps to
    @State private var account: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                ForEach(Page.sections, id: \.0) { section in
                    Section(section.0) {
                        // without a Git folder there is nothing to sync, and with a ledger that reads cleanly no errors to list
                        ForEach(section.1.filter { ($0 != .sync || git != nil) && ($0 != .errors || !ledger.errors.isEmpty || page == .errors) }, id: \.self) { item in
                            row(item, badge: badge(item))
                        }
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
                switch page ?? .overview {
                case .overview:
                    drillable { OverviewPage(ledger: ledger, config: config, folder: folder, git: git, alerts: alerts, period: $period, page: $page) }
                case .journal: JournalPage(ledger: ledger, config: config, folder: folder, scope: nil, period: period, account: account, searching: $searching)
                case .accounts:
                    drillable { AccountsPage(ledger: ledger, config: config, folder: folder) }
                case .reports: drillable { ReportsPage(ledger: ledger, config: config, period: period) }
                case .payees: PayeesPage(ledger: ledger, config: config, folder: folder)
                case .year: drillable { YearPage(ledger: ledger, config: config, period: period) }
                case .budgets: drillable { BudgetsPage(ledger: ledger, period: period) }
                case .forecast: drillable { ForecastPage(ledger: ledger, config: config) }
                case .subscriptions: drillable { SubscriptionsPage(ledger: ledger, config: config, folder: folder) }
                case .reimbursements: drillable { ReimbursementsPage(ledger: ledger, config: config, folder: folder) }
                case .salary: SalaryPage(ledger: ledger, config: config, folder: folder)
                case .events: EventsPage(ledger: ledger, config: config, folder: folder)
                case .query: QueryPage(ledger: ledger, folder: folder)
                case .errors: ErrorsPage(ledger: ledger, folder: folder)
                case .sync:
                    SyncPage(folder: folder, status: git, remoteReached: remoteReached) { gitReads += 1 }
                }
            }
            // a list of its own for each page: left to reuse its rows, one page's row keeps what the last page's row did when clicked
            .id(page ?? .overview)
            .safeAreaInset(edge: .bottom) {
                if page != .errors { ErrorBar(errors: ledger.errors.filter { !$0.soft }) { page = .errors } }
            }
            .toolbar {
                // a row's entries, a level down, keep to what the row counted
                if (page ?? .overview).followsPeriod && !inScope {
                    ToolbarItemGroup(placement: .navigation) {
                        PeriodBar(period: $period)
                        if page == .journal { AccountFilter(ledger: ledger, account: $account) }
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
        .task(id: "\(changes)|\(gitReads)|\(folder.path)") {
            let folder = folder
            let status = await Task.detached { folderGitStatus(folder) }.value
            guard !Task.isCancelled else { return }
            git = status
        }
        .task(id: folder.path) { checkRemote() }
        // what the phone lists as 值得留意, less what was checked and found fine there or here (ledger-x.json)
        .task(id: "\(ObjectIdentifier(ledger))|\(config?.alertsConfirmed ?? [])|\(config?.largeExpense ?? 0)") {
            let ledger = ledger, settings = AnomalySettings(large: config?.largeExpense ?? 2000), confirmed = Set(config?.alertsConfirmed ?? [])
            let found = await Task.detached { anomalies(ledger, settings: settings) }.value
            guard !Task.isCancelled else { return }
            alerts = found.filter { !confirmed.contains($0.id) }
        }
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

    private func badge(_ item: Page) -> Int {
        switch item {
        case .overview: return alerts.count
        case .errors: return ledger.errors.count
        case .sync: return git.map { $0.paths.count + $0.ahead + $0.behind } ?? 0
        default: return 0
        }
    }

    /// the tag outermost: a badge put on after it hides the row from the list's selection
    private func row(_ item: Page, badge: Int = 0) -> some View {
        Label(item.title, systemImage: item.symbol).badge(badge).tag(item)
    }

    /// a row of the page opens the entries it counts, a level down; the journal is all entries already, and its search box needs no stack around it
    private func drillable(@ViewBuilder _ page: () -> some View) -> some View {
        NavigationStack {
            page().navigationDestination(for: JournalScope.self) { scope in
                JournalPage(ledger: ledger, config: config, folder: folder, scope: scope, period: period, account: account, searching: $searching)
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

/// a ledger that didn't read cleanly can be missing entries, so this stays in sight; a click lists them all
private struct ErrorBar: View {
    let errors: [LedgerError]
    let open: () -> Void

    var body: some View {
        if let first = errors.first {
            Button(action: open) {
                Text(errors.count > 1 ? "\(first.msg) (+\(errors.count - 1))" : first.msg)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(first.msg)
            .background(.bar)
        }
    }
}
