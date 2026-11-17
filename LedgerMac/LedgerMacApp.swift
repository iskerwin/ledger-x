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
    @State private var open = OpenLedger()
    @AppStorage(MacLanguage.key) private var language = MacLanguage.system.rawValue

    init() {
        MacLanguage.apply()
        KitPrivacy.masked = UserDefaults.standard.bool(forKey: "hideAmounts")
        _page = State(initialValue: Page(rawValue: UserDefaults.standard.string(forKey: "defaultPage") ?? "") ?? .overview)
    }

    var body: some Scene {
        Window("Ledger X", id: "main") {
            ContentView(folder: folder, opened: opened, picking: $picking, adding: $adding, page: $page, searching: $searching)
                // dates as the words around them, whatever the system's first language is
                .environment(\.locale, MacLanguage.current.locale)
                // every page drawn again in the other language
                .id(language)
                .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
                .onChange(of: hideAmounts) { KitPrivacy.masked = hideAmounts }
                // the window's view made again (`id`) reads the ledger again, with LedgerKit's words in the new language
                .onChange(of: language) { MacLanguage.apply() }
                .environment(open)
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
                Button(LS("记一笔…")) { withoutSheet { adding = true } }
                    .keyboardShortcut("n")
                    .disabled(folder.isEmpty)
                Button(LS("打开账本…")) { withoutSheet { picking = true } }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .textEditing) {
                Button(LS("搜索")) {
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
                Toggle(LS("隐藏金额"), isOn: $hideAmounts)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
            }
            EntryCommands()
            CommandGroup(replacing: .help) { GuideButton() }
        }
        Window(LS("记一笔"), id: EntryWindow.id) {
            EntryWindow()
                .environment(open)
                .environment(\.locale, MacLanguage.current.locale)
                .id(language)
                .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()
        Window(LS("使用指南"), id: MacGuide.id) {
            MacGuide()
                .environment(\.locale, MacLanguage.current.locale)
                .id(language)
                .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
        }
        .defaultSize(width: 640, height: 720)
        .commandsRemoved()
        Settings {
            SettingsView(folder: folder, picking: $picking)
                .environment(\.locale, MacLanguage.current.locale)
                .id(language)
                .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
        }
    }
}

/// a sheet's form would be lost if the page behind it changed, and menu shortcuts still reach here while one is up
@MainActor
func withoutSheet(_ action: () -> Void) {
    if NSApp.keyWindow?.isSheet != true { action() }
}

/// 交易: what right-clicking the picked entries offers, for the journal or an account's entries on screen
private struct EntryCommands: Commands {
    @FocusedValue(\.entryMenu) private var entryMenu

    var body: some Commands {
        CommandMenu(LS("交易")) {
            let items = entryMenu?.items() ?? []
            if items.isEmpty {
                // nothing picked: the lines every entry has, to be found here before picking one
                ForEach([LS("编辑…"), LS("复制为新交易…"), LS("复制原文"), LS("打开所在文件"), LS("删除…")], id: \.self) { title in
                    Button(title) {}
                        .keyboardShortcut(title == LS("复制为新交易…") ? EntryMenu.duplicate : nil)
                        .disabled(true)
                }
            } else {
                ForEach(items.indices, id: \.self) { i in
                    if let run = items[i].run {
                        Button(items[i].title) { withoutSheet(run) }
                            .keyboardShortcut(items[i].key)
                            .disabled(!items[i].enabled)
                    } else {
                        Divider()
                    }
                }
            }
        }
    }
}

/// 帮助 › Ledger X 使用指南
private struct GuideButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(LS("Ledger X 使用指南")) { openWindow(id: MacGuide.id) }
            .keyboardShortcut("?", modifiers: .command)
    }
}

private struct ContentView: View {
    let folder: String
    let opened: Int
    @Binding var picking: Bool
    @Binding var adding: Bool
    @Binding var page: Page?
    @Binding var searching: Bool
    @Environment(OpenLedger.self) private var open
    @State private var missing = false
    @State private var watcher: FolderWatcher?
    /// which folder and opening is on screen: while it stays the same, a reload keeps the old list up until the new one is ready
    @State private var source = ""
    @State private var changes = 0
    @State private var readings = SerialWork()
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if let ledger = open.ledger {
                MainView(ledger: ledger, config: open.config, folder: URL(fileURLWithPath: folder), changes: changes, adding: $adding, page: $page, searching: $searching)
            } else if folder.isEmpty || missing {
                VStack(spacing: 12) {
                    if missing { Text(LS("这个文件夹里没有账本")).foregroundStyle(.secondary) }
                    Button(LS("打开账本")) { picking = true }
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(WindowReader { $0.fitScreen() })
        .navigationTitle(folder.isEmpty ? "Ledger X" : URL(fileURLWithPath: folder).lastPathComponent)
        // saves are undone from this window's 编辑 › 撤销
        .onAppear { SaveUndo.manager = undoManager }
        .onChange(of: undoManager) { SaveUndo.manager = undoManager }
        .task(id: "\(changes)|\(opened)|\(folder)") {
            guard !folder.isEmpty else { return }
            let url = URL(fileURLWithPath: folder)
            if source != "\(opened)|\(folder)" {
                source = "\(opened)|\(folder)"
                open.folder = url
                open.ledger = nil
                missing = false
                SaveUndo.opened(url)
                watcher = FolderWatcher(url) { changes += 1 }
            }
            // one reading at a time: changes that arrive during one end in a single reading after it
            guard let loaded = await readings.run({ (loadLedger(folder: url), ledgerConfig(folder: url)) }), !Task.isCancelled else { return }
            open.ledger = loaded.0
            open.config = loaded.1
            missing = loaded.0 == nil
        }
    }
}
