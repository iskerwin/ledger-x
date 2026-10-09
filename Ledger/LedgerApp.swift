import SwiftUI
import LedgerKit

@main
struct LedgerApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(store.drafts)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .tint(.jade)
                .task { await store.start() }
                .onChange(of: phase) { _, p in
                    if p == .active { Task { await store.refresh() } }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if !store.connected {
                NavigationStack { SettingsView(first: true) }
            } else if store.L == nil {
                NavigationStack { LoadingView() }
            } else {
                TabView(selection: $store.tab) {
                    AddView().tabItem { Label("记一笔", systemImage: "square.and.pencil") }.tag(Tab.add)
                    OverviewView().tabItem { Label("概览", systemImage: "chart.bar") }.tag(Tab.overview)
                    JournalView().tabItem { Label("流水", systemImage: "list.bullet.rectangle") }.tag(Tab.journal)
                    AccountsView().tabItem { Label("账户", systemImage: "building.columns") }.tag(Tab.accounts)
                    NavigationStack { SettingsView() }.tabItem { Label("设置", systemImage: "gearshape") }.tag(Tab.settings)
                }
            }
        }
        .overlay(alignment: .bottom) { ToastView().animation(.spring(duration: 0.3), value: store.toast) }
    }
}

struct LoadingView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: 16) {
            Image("Logo").resizable().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 16))
            if let e = store.loadError ?? (store.syncState == .error || store.syncState == .offline ? store.syncError : nil), !e.isEmpty {
                Text(e).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
                Button("重试") { Task { await store.refresh() } }.buttonStyle(.borderedProminent).tint(.jade)
                NavigationLink("设置") { SettingsView() }
            } else {
                ProgressView()
                Text("正在读取账本…").foregroundStyle(.secondary)
            }
        }
    }
}
