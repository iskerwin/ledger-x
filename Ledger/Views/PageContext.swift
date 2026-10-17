import SwiftUI
import LedgerKit

/// Keep each tab's stack while switching ledgers. Paths remain in memory, scoped to a ledger.
private struct LedgerNavigation: ViewModifier {
    @EnvironmentObject private var store: Store
    let page: String
    @Binding var path: NavigationPath
    @State private var ledgerID = ""

    func body(content: Content) -> some View {
        content
            .onAppear { if ledgerID.isEmpty { restore() } }
            .onChange(of: store.cfg.id) { _, _ in restore() }
            .onChange(of: path) { _, value in
                guard ledgerID == store.cfg.id else { return }
                store.navigationContexts[ledgerID, default: [:]][page] = value
            }
    }

    private func restore() {
        ledgerID = store.cfg.id
        path = store.navigationContexts[ledgerID]?[page] ?? NavigationPath()
    }
}

/// Save controls immediately, so app relaunches and ledger switches restore their own filters.
private struct LedgerControls: ViewModifier {
    @EnvironmentObject private var store: Store
    let page: String
    @Binding var value: BrowseContext
    @State private var ledgerID = ""

    func body(content: Content) -> some View {
        content
            .onAppear { if ledgerID.isEmpty { restore() } }
            .onChange(of: store.cfg.id) { _, _ in restore() }
            .onChange(of: value) { _, current in
                guard ledgerID == store.cfg.id, !store.demo else { return }
                var all = Prefs.get(Store.key("pageContexts", ledgerID), [String: BrowseContext]())
                all[page] = current
                Prefs.set(Store.key("pageContexts", ledgerID), all)
            }
    }

    private func restore() {
        ledgerID = store.cfg.id
        guard !store.demo else { return }
        var all = Prefs.get(Store.key("pageContexts", ledgerID), [String: BrowseContext]())
        if let saved = all[page] { value = saved }
        else {
            all[page] = value
            Prefs.set(Store.key("pageContexts", ledgerID), all)
        }
    }
}

extension View {
    func ledgerNavigation(_ page: String, path: Binding<NavigationPath>) -> some View {
        modifier(LedgerNavigation(page: page, path: path))
    }
    func ledgerControls(_ page: String, value: Binding<BrowseContext>) -> some View {
        modifier(LedgerControls(page: page, value: value))
    }
}
