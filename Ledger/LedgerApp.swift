import SwiftUI
import UserNotifications
import LedgerKit

@main
struct LedgerApp: App {
    @StateObject private var store = Store.shared
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var phase
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

    init() {
        AppLanguage.apply()
        KitPrivacy.masked = AppSettings.shared.privacy
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                if lock.locked {
                    LockScreen().transition(.opacity).zIndex(2)
                } else if phase != .active && lock.enabled {
                    PrivacyCover().zIndex(1)
                }
            }
            .environmentObject(store)
            .environmentObject(store.drafts)
            .environmentObject(lock)
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.scheme)
            .task {
                NotificationRouter.shared.open = { [store] t in
                    if let tab = Tab(rawValue: t), tab != .add { store.tab = tab } else { store.openAdd() }
                }
                if lock.locked { Task { await lock.unlock() } }
                await store.start()
            }
            .onOpenURL { url in
                // ledgerx://add (Shortcuts, notifications)
                if url.host == "add" { store.openAdd() }
                else if let t = Tab(rawValue: url.host ?? "") { store.tab = t }
            }
            .onChange(of: phase) { _, p in
                if p != .active { store.persistActiveDraft() }
                lock.scenePhase(p)
                if p == .active { Task { await store.refresh() } }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.horizontalSizeClass) private var hsize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !store.connected {
                NavigationStack { SettingsView(first: true) }
            } else if store.L == nil {
                NavigationStack { LoadingView() }
            } else if hsize == .regular {
                SplitRoot()
            } else {
                // 记一笔 sits in the middle as a tab that never shows a page: it opens the card over the tab in use
                TabView(selection: Binding(get: { store.tab }, set: { t in if t == .add { store.openAdd() } else { store.tab = t } })) {
                    OverviewView().tabItem { Label(LS("概览"), systemImage: "chart.bar.xaxis") }.tag(Tab.overview)
                    JournalView().tabItem { Label(LS("明细"), systemImage: "list.bullet.rectangle.portrait") }.tag(Tab.journal)
                    Color.clear.tabItem { Label(Tab.add.title, systemImage: Tab.add.symbol) }.tag(Tab.add)
                    AccountsView().tabItem { Label(LS("账户"), systemImage: "building.columns") }.tag(Tab.accounts)
                    ReportsView().tabItem { Label(LS("报表"), systemImage: "doc.text.magnifyingglass") }.tag(Tab.reports)
                }
                .minimizingTabBar()
            }
        }
        // read while drawing, so a new theme or language redraws in place
        .tint(AppTheme.current.color)
        .environment(\.locale, AppLanguage.current.locale)
        // The open 记一笔 card draws the same toast itself. Showing both at once made one save appear twice.
        .overlay(alignment: .bottom) {
            if !store.adding { ToastView().animation(.spring(duration: 0.3), value: store.toast) }
        }
        .sheet(item: $store.scanResult) { r in
            ScanResultView(result: r)
                .tint(AppTheme.current.color)
                .environment(\.locale, AppLanguage.current.locale)
        }
        .sheet(isPresented: $store.adding, onDismiss: { store.endEdit() }) {
            // a sheet doesn't inherit what is set on the view it hangs from: the theme and language again
            AddCard()
                .tint(AppTheme.current.color)
                .environment(\.locale, AppLanguage.current.locale)
                .presentationDragIndicator(.visible)
        }
        // while the card is open it shows these itself (a sheet can't open under another)
        .sheet(item: store.adding ? .constant(nil) : $store.subSuggestion) { c in SubEditSheet(draft: SubDraft(c)) }
        .sheet(item: $store.repaying) { RepaySheet(cycle: $0) }
        .sheet(isPresented: $store.showSync) {
            NavigationStack {
                SyncView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button { store.showSync = false } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }.fontWeight(.semibold) } }
            }
            .tint(AppTheme.current.color)
            .environment(\.locale, AppLanguage.current.locale)
        }
        .sheet(isPresented: $store.showSettings, onDismiss: {
            if store.openCheckAfterSettings { store.openCheckAfterSettings = false; store.openCheck = true }
        }) {
            NavigationStack {
                SettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button { store.showSettings = false } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }.fontWeight(.semibold) } }
            }
        }
        .transaction { if reduceMotion { $0.animation = nil } }
    }
}

struct LoadingView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: AppSpacing.content) {
            Image("Logo").resizable().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let e = store.loadError ?? (store.syncState == .error || store.syncState == .offline ? store.syncError : nil), !e.isEmpty {
                Text(e).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, AppSpacing.content)
                Button { Task { await store.refresh() } } label: { Label(LS("重试"), systemImage: "arrow.clockwise").labelStyle(ControlLabelStyle()) }.buttonStyle(.borderedProminent)
                NavigationLink { SettingsView() } label: { Label(LS("设置"), systemImage: "gearshape").labelStyle(ControlLabelStyle()) }
            } else {
                ProgressView()
                Text(LS("正在加载账本…")).foregroundStyle(.secondary)
            }
        }
    }
}


/// iPad / wide windows: a sidebar with the sections, the section on the right
struct SplitRoot: View {
    @EnvironmentObject var store: Store
    @State private var visibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: Binding<Tab?>(get: { store.tab }, set: { if let t = $0 { if t == .add { store.openAdd() } else { store.tab = t } } })) {
                Section {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Label(t.title, systemImage: t.symbol).labelStyle(ControlLabelStyle()).tag(t)
                    }
                }
                Section {
                    Button { store.showSettings = true } label: { Label(LS("设置"), systemImage: "gearshape").labelStyle(ControlLabelStyle()) }
                    if let L = store.L, let D = store.D {
                        let m = Day.ym(Day.today())
                        VStack(alignment: .leading, spacing: AppSpacing.detail) {
                            Text(LS("本月支出")).font(.caption).foregroundStyle(.secondary)
                            Text(money(D.monthExp[m] ?? 0, L.base)).font(.title3.weight(.semibold)).monospacedDigit().sensitive()
                        }
                        .padding(.vertical, AppSpacing.detail)
                    }
                }
            }
            .navigationTitle("Ledger X")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            switch store.tab {
            case .add, .overview: OverviewView()
            case .journal: JournalView()
            case .accounts: AccountsView()
            case .reports: ReportsView()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
