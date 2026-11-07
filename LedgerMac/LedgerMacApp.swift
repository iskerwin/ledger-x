import SwiftUI
import UniformTypeIdentifiers
import LedgerKit

let chinese = (Locale.preferredLanguages.first ?? "zh").hasPrefix("zh")

@main
struct LedgerMacApp: App {
    @AppStorage("ledgerFolder") private var folder = ""
    @State private var picking = false
    @State private var adding = false
    /// counts the times a folder was chosen, so choosing the same one again reads it again
    @State private var opened = 0

    init() {
        KitLocale.chinese = chinese
    }

    var body: some Scene {
        Window("Ledger X", id: "main") {
            ContentView(folder: folder, opened: opened, picking: $picking, adding: $adding)
                .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result {
                        folder = url.path
                        opened += 1
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(chinese ? "记一笔…" : "New Entry…") { adding = true }
                    .keyboardShortcut("n")
                    .disabled(folder.isEmpty)
                Button(chinese ? "打开账本…" : "Open Ledger…") { picking = true }
                    .keyboardShortcut("o")
            }
        }
    }
}

private struct ContentView: View {
    let folder: String
    let opened: Int
    @Binding var picking: Bool
    @Binding var adding: Bool
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
                MainView(ledger: ledger, config: config, folder: URL(fileURLWithPath: folder), changes: changes, adding: $adding)
            } else if folder.isEmpty || missing {
                VStack(spacing: 12) {
                    if missing { Text(chinese ? "这个文件夹里没有账本" : "No ledger in this folder").foregroundStyle(.secondary) }
                    Button(chinese ? "打开账本" : "Open Ledger") { picking = true }
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 400)
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
