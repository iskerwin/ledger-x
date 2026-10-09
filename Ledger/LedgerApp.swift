import SwiftUI
import LedgerKit

@main
struct LedgerApp: App {
    @StateObject private var store = Store()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var phase
    @AppStorage(AppTheme.key) private var theme = AppTheme.jade.rawValue
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

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
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .tint(AppTheme(rawValue: theme)?.color ?? .jade)
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.scheme)
            .task {
                if lock.locked { await lock.unlock() }
                await store.start()
            }
            .onChange(of: phase) { _, p in
                lock.scenePhase(p)
                if p == .active { Task { await store.refresh() } }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @AppStorage(AppTheme.key) private var theme = AppTheme.jade.rawValue

    var body: some View {
        Group {
            if !store.connected {
                NavigationStack { SettingsView(first: true) }
            } else if store.L == nil {
                NavigationStack { LoadingView() }
            } else {
                TabView(selection: $store.tab) {
                    AddView().tabItem { Label("记账", systemImage: "square.and.pencil") }.tag(Tab.add)
                    OverviewView().tabItem { Label("概览", systemImage: "chart.bar.xaxis") }.tag(Tab.overview)
                    JournalView().tabItem { Label("明细", systemImage: "list.bullet.rectangle.portrait") }.tag(Tab.journal)
                    AccountsView().tabItem { Label("账户", systemImage: "building.columns") }.tag(Tab.accounts)
                    ReportsView().tabItem { Label("报表", systemImage: "doc.text.magnifyingglass") }.tag(Tab.reports)
                }
                .minimizingTabBar()
                .id(theme)   // theme colours are static; rebuild the tabs when it changes
            }
        }
        .overlay(alignment: .bottom) { ToastView().animation(.spring(duration: 0.3), value: store.toast) }
        .sheet(isPresented: $store.showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { store.showSettings = false }.fontWeight(.semibold) } }
            }
        }
    }
}

struct LoadingView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: 16) {
            Image("Logo").resizable().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let e = store.loadError ?? (store.syncState == .error || store.syncState == .offline ? store.syncError : nil), !e.isEmpty {
                Text(e).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
                Button("重试") { Task { await store.refresh() } }.buttonStyle(.borderedProminent)
                NavigationLink("设置") { SettingsView() }
            } else {
                ProgressView()
                Text("正在加载账本…").foregroundStyle(.secondary)
            }
        }
    }
}
