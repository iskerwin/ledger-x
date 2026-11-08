import SwiftUI
import UniformTypeIdentifiers
import LedgerKit

@main
struct LedgerMacApp: App {
    @AppStorage("ledgerFolder") private var folder = ""
    @State private var picking = false
    @State private var adding = false
    @State private var page: Page?
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @AppStorage("hideAmounts") private var hideAmounts = false
    @State private var searching = false
    /// counts the times a folder was chosen, so choosing the same one again reads it again
    @State private var opened = 0

    init() {
        KitLocale.chinese = true
        KitPrivacy.masked = UserDefaults.standard.bool(forKey: "hideAmounts")
        _page = State(initialValue: Page(rawValue: UserDefaults.standard.string(forKey: "defaultPage") ?? "") ?? .overview)
    }

    var body: some Scene {
        Window("Ledger X", id: "main") {
            ContentView(folder: folder, opened: opened, picking: $picking, adding: $adding, page: $page, searching: $searching)
                // dates as the words around them, whatever the system's first language is
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
                .onChange(of: hideAmounts) { KitPrivacy.masked = hideAmounts }
                .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result {
                        folder = url.path
                        opened += 1
                    }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("记一笔…") { withoutSheet { adding = true } }
                    .keyboardShortcut("n")
                    .disabled(folder.isEmpty)
                Button("打开账本…") { withoutSheet { picking = true } }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .textEditing) {
                Button("搜索") {
                    withoutSheet {
                        // the box may have lost focus without closing: closing it first brings it back every time
                        searching = false
                        DispatchQueue.main.async { searching = true }
                    }
                }
                .keyboardShortcut("f")
                .disabled(folder.isEmpty)
            }
            CommandGroup(before: .sidebar) {
                // ⌘1 to ⌘9 for the first nine, in the sidebar's order
                ForEach(Array(Page.sections.enumerated()), id: \.offset) { _, section in
                    ForEach(section.1, id: \.self) { item in
                        let index = Page.allCases.firstIndex(of: item) ?? 99
                        Button(item.title) { withoutSheet { page = item } }
                            .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1)))) : nil)
                            .disabled(folder.isEmpty)
                    }
                    Divider()
                }
                Toggle("隐藏金额", isOn: $hideAmounts)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
            }
        }
        Settings {
            SettingsView(folder: folder, picking: $picking)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
        }
    }

    /// a sheet's form would be lost if the page behind it changed, and menu shortcuts still reach here while one is up
    private func withoutSheet(_ action: () -> Void) {
        if NSApp.keyWindow?.isSheet != true { action() }
    }
}

private struct ContentView: View {
    let folder: String
    let opened: Int
    @Binding var picking: Bool
    @Binding var adding: Bool
    @Binding var page: Page?
    @Binding var searching: Bool
    @State private var ledger: Ledger?
    @State private var config: LedgerXConfig?
    @State private var missing = false
    @State private var watcher: FolderWatcher?
    /// which folder and opening is on screen: while it stays the same, a reload keeps the old list up until the new one is ready
    @State private var source = ""
    @State private var changes = 0

    var body: some View {
        Group {
            if let ledger {
                MainView(ledger: ledger, config: config, folder: URL(fileURLWithPath: folder), changes: changes, adding: $adding, page: $page, searching: $searching, picking: $picking)
            } else if folder.isEmpty || missing {
                VStack(spacing: 12) {
                    if missing { Text("这个文件夹里没有账本").foregroundStyle(.secondary) }
                    Button("打开账本") { picking = true }
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .navigationTitle(folder.isEmpty ? "Ledger X" : URL(fileURLWithPath: folder).lastPathComponent)
        .task(id: "\(changes)|\(opened)|\(folder)") {
            guard !folder.isEmpty else { return }
            let url = URL(fileURLWithPath: folder)
            if source != "\(opened)|\(folder)" {
                source = "\(opened)|\(folder)"
                ledger = nil
                missing = false
                watcher = FolderWatcher(url) { changes += 1 }
            }
            let loaded = await Task.detached { (loadLedger(folder: url), ledgerConfig(folder: url)) }.value
            guard !Task.isCancelled else { return }
            ledger = loaded.0
            config = loaded.1
            missing = loaded.0 == nil
        }
    }
}
