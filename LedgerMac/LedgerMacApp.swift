import SwiftUI
import UniformTypeIdentifiers
import LedgerKit

private let chinese = (Locale.preferredLanguages.first ?? "zh").hasPrefix("zh")

@main
struct LedgerMacApp: App {
    @AppStorage("ledgerFolder") private var folder = ""
    @State private var picking = false
    /// counts the times a folder was chosen, so choosing the same one again reads it again
    @State private var opened = 0

    init() {
        KitLocale.chinese = chinese
    }

    var body: some Scene {
        Window("Ledger X", id: "main") {
            ContentView(folder: folder, opened: opened, picking: $picking)
                .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result {
                        folder = url.path
                        opened += 1
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
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
    @State private var ledger: Ledger?
    @State private var missing = false

    var body: some View {
        Group {
            if let ledger {
                JournalList(ledger: ledger)
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
        .frame(minWidth: 560, minHeight: 400)
        .navigationTitle(folder.isEmpty ? "Ledger X" : URL(fileURLWithPath: folder).lastPathComponent)
        .task(id: "\(opened)|\(folder)") {
            ledger = nil
            missing = false
            guard !folder.isEmpty else { return }
            let url = URL(fileURLWithPath: folder)
            let loaded = await Task.detached { loadLedger(folder: url) }.value
            guard !Task.isCancelled else { return }
            ledger = loaded
            missing = loaded == nil
        }
    }
}

private struct JournalList: View {
    let ledger: Ledger
    private let rows: [Entry]
    private let errors: [LedgerError]

    init(ledger: Ledger) {
        self.ledger = ledger
        rows = ledger.txns.reversed()
        errors = ledger.errors.filter { !$0.soft }
    }

    var body: some View {
        List(rows.indices, id: \.self) { index in
            JournalRow(entry: rows[index], ledger: ledger)
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .bottom) {
            // a ledger that didn't read cleanly can be missing entries, so this stays in sight
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
}

private struct JournalRow: View {
    let entry: Entry
    let ledger: Ledger

    var body: some View {
        HStack(spacing: 16) {
            Text(entry.date)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(entry.payee.isEmpty ? entry.narration : entry.payee)
                .lineLimit(1)
            if !entry.payee.isEmpty && !entry.narration.isEmpty {
                Text(entry.narration)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing) {
                ForEach(amounts, id: \.self) { Text($0).monospacedDigit() }
            }
            .foregroundStyle(isTransfer ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }

    private var isTransfer: Bool { classify(entry, ledger).kind == .transfer }

    /// as in the phone's journal: a transfer's amount, else what was spent or earned in each currency as booked
    private var amounts: [String] {
        let shown = classify(entry, ledger)
        if shown.kind == .transfer { return [money(shown.amount, shown.currency ?? "CNY")] }
        var order: [String] = [], sums: [String: Double] = [:]
        for posting in entry.postings where posting.account.hasPrefix("Expenses:") || posting.account.hasPrefix("Income:") {
            guard let units = posting.units, let currency = posting.currency else { continue }
            if sums[currency] == nil { order.append(currency) }
            sums[currency, default: 0] -= units
        }
        return order.map { signedMoney(sums[$0]!, $0) }
    }
}
