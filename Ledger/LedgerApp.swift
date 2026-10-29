import SwiftUI
import UserNotifications
import LedgerKit

@main
struct LedgerApp: App {
    @State private var store = Store.shared
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var phase
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

    init() {
        AppLanguage.apply()
        KitPrivacy.masked = AppSettings.shared.privacy
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    /// up while locked, and (lock on) while the app is not in front, for the app switcher snapshot
    private func updateCover(_ p: ScenePhase) {
        if lock.locked || (p != .active && lock.enabled) {
            CoverWindow.shared.show(CoverView().environment(lock).preferredColorScheme(AppAppearance(rawValue: appearance)?.scheme))
        } else {
            CoverWindow.shared.hide()
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                // Locked means locked, and an open sheet stays open: the lock screen and the app switcher cover
                // are in a window above this one (CoverWindow), so they cover every sheet; unlocking takes that
                // window away and leaves the sheets, and what was typed into them, as they were (they used to be
                // torn down by taking the app's views away while locked). Until that window is up on launch,
                // this blank covers the app.
                if lock.locked { Color(.systemGroupedBackground).ignoresSafeArea() }
            }
            .environment(store)
            .environment(store.drafts)
            .environment(lock)
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.scheme)
            .task {
                NotificationRouter.shared.open = { [store] t in
                    if let tab = Tab(rawValue: t), tab != .add { store.tab = tab } else { store.openAdd() }
                }
                updateCover(phase)
                if lock.locked && !AppLock.testing { Task { await lock.unlock() } }
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
                updateCover(p)
                if p == .active { store.dayMayHaveChanged(); Task { await store.refreshOnReturn() } }
            }
            // midnight while the app is open (delivered on return when it passed in the background)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                store.dayMayHaveChanged()
            }
            .onChange(of: lock.locked) { updateCover(phase) }
        }
    }
}

struct RootView: View {
    @Environment(Store.self) var store
    @Environment(\.horizontalSizeClass) private var hsize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !store.connected {
                NavigationStack { SettingsView(first: true) }
            } else if store.L == nil && LoadingView.problem(store) != nil {
                // a ledger that couldn't load: why, and what to do; while it loads the pages show their shape instead
                NavigationStack { LoadingView() }
            } else if hsize == .regular {
                SplitRoot()
            } else {
                // 记一笔 sits in the middle as a tab that never shows a page: it opens the card over the tab in use
                TabView(selection: Binding(get: { store.tab }, set: { t in if t == .add { store.openAdd() } else { store.tab = t } })) {
                    OverviewView().tabFade().tabItem { Label(LS("概览"), systemImage: "chart.bar.xaxis") }.tag(Tab.overview)
                    JournalView().tabFade().tabItem { Label(LS("明细"), systemImage: "list.bullet.rectangle.portrait") }.tag(Tab.journal)
                    Color.clear.tabItem { Label(Tab.add.title, systemImage: Tab.add.symbol) }.tag(Tab.add)
                    AccountsView().tabFade().tabItem { Label(LS("账户"), systemImage: "building.columns") }.tag(Tab.accounts)
                    ReportsView().tabFade().tabItem { Label(LS("报表"), systemImage: "doc.text.magnifyingglass") }.tag(Tab.reports)
                }
                .minimizingTabBar()
            }
        }
        // read while drawing, so a new theme or language redraws in place
        .tint(Color.jadeInk)
        .environment(\.locale, AppLanguage.current.locale)
        // The open 记一笔 card draws the same toast itself. Showing both at once made one save appear twice.
        .overlay(alignment: .bottom) {
            if !store.adding { ToastView().animation(AppMotion.emphasized, value: store.toast) }
        }
        .sheet(item: Bindable(store).scanResult) { r in
            ScanResultView(result: r)
                .tint(Color.jadeInk)
                .environment(\.locale, AppLanguage.current.locale)
        }
        .sheet(isPresented: Bindable(store).adding, onDismiss: { store.endEdit() }) {
            // a sheet doesn't inherit what is set on the view it hangs from: the theme and language again
            AddCard()
                .tint(Color.jadeInk)
                .environment(\.locale, AppLanguage.current.locale)
                .presentationDragIndicator(.visible)
        }
        // while the card is open it shows these itself (a sheet can't open under another)
        .sheet(item: store.adding ? .constant(nil) : Bindable(store).subSuggestion) { c in SubEditSheet(draft: SubDraft(c)) }
        .sheet(item: Bindable(store).repaying) { RepaySheet(cycle: $0) }
        .sheet(isPresented: Bindable(store).showSync) {
            NavigationStack {
                SyncView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button { store.showSync = false } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }.fontWeight(.semibold) } }
            }
            .tint(Color.jadeInk)
            .environment(\.locale, AppLanguage.current.locale)
        }
        .sheet(isPresented: Bindable(store).showSettings, onDismiss: {
            if store.openCheckAfterSettings { store.openCheckAfterSettings = false; store.openCheck = true }
        }) {
            NavigationStack {
                SettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button { store.showSettings = false } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }.fontWeight(.semibold) } }
            }
            // the window's toast is under this sheet: what is done in 设置 says so here
            .overlay(alignment: .bottom) { ToastView().animation(AppMotion.emphasized, value: store.toast) }
        }
        .transaction { if reduceMotion { $0.animation = nil } }
    }
}

/// a tab fades in when it is switched to; the system switches tabs without any transition
private struct TabFade: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .onAppear { withAnimation(AppMotion.quick) { shown = true } }
            .onDisappear { shown = false }
    }
}

private extension View {
    func tabFade() -> some View { modifier(TabFade()) }
}

struct LoadingView: View {
    @Environment(Store.self) var store
    /// why the ledger didn't load, if it didn't
    static func problem(_ store: Store) -> String? {
        guard let e = store.loadError ?? (store.syncState == .error || store.syncState == .offline ? store.syncError : nil), !e.isEmpty else { return nil }
        return e
    }
    var body: some View {
        VStack(spacing: AppSpacing.content) {
            Image("Logo").resizable().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let e = Self.problem(store) {
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
    @Environment(Store.self) var store
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
