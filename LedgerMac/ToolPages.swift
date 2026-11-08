import SwiftUI
import UniformTypeIdentifiers
import LedgerKit

/// 值得留意 checked and found fine, set aside on every device: ledger-x.json, as the phone keeps it
func confirmAlert(_ alert: Anomaly, folder: URL) throws {
    let save = try prepareFolderConfig(folder: folder) { config in
        var ids = config.alertsConfirmed ?? []
        if !ids.contains(alert.id) { ids.append(alert.id) }
        config.alertsConfirmed = ids
    }.get()
    try commitFolderSave(save, folder: folder)
}

extension Anomaly.Kind {
    var symbol: String {
        switch self {
        case .duplicate: return "doc.on.doc"
        case .large: return "dollarsign.circle"
        case .category: return "chart.line.uptrend.xyaxis"
        case .subscription: return "repeat"
        }
    }
}

/// BQL against the ledger: the built-in queries and the ledger's own on the left, the text, ⌘↩ to run it, and the result in a table
struct QueryPage: View {
    let ledger: Ledger
    let folder: URL
    @AppStorage("queryText") private var text = builtinQueries.first?.text ?? ""
    @State private var picked: String?
    @State private var result: QueryResult?
    @State private var failure: String?
    @State private var took: Double = 0

    var body: some View {
        let saved = ledgerQueries
        SplitPage(listWidth: 240) {
            ForEach([("内置", builtinQueries), ("账本", saved)], id: \.0) { group in
                if !group.1.isEmpty {
                    Text(group.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
                    ForEach(group.1) { query in
                        PickRow(title: query.name, picked: picked == query.id) {
                            picked = query.id
                            text = query.text
                            run()
                        }
                    }
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 140)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: 8) {
                    Button("运行", action: run)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                    Spacer()
                    if let result {
                        Text("\(result.rows.count) 行 · " + String(format: "%.2f 秒", took)).monospacedDigit().foregroundStyle(.secondary)
                        Button("复制") { copy(result) }
                        Button("导出 CSV…") { export(result) }
                    }
                }
                if let failure {
                    Text(failure).foregroundStyle(Color.loss).textSelection(.enabled)
                }
                if let result {
                    ResultTable(result: result)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .onAppear { if result == nil && failure == nil { run() } }
        .onChange(of: ObjectIdentifier(ledger)) { if result != nil { run() } }
    }

    /// `query` directives, then the .bql files in the folder, as the phone lists them
    private var ledgerQueries: [SavedQuery] {
        let directives = ledger.entries.filter { $0.type == .query }.compactMap { entry -> SavedQuery? in
            guard let query = entry.query?.trimmed, !query.isEmpty else { return nil }
            return SavedQuery(id: "query:" + (entry.name ?? query), name: entry.name ?? "query", text: query, source: "ledger")
        }
        var files: [SavedQuery] = []
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker where url.pathExtension == "bql" {
                let path = String(url.path.dropFirst(folder.path.count + 1))
                if let content = try? String(contentsOf: url, encoding: .utf8) { files += parseBQLFile(content, file: path) }
            }
        }
        return directives + files.sorted { $0.id < $1.id }
    }

    private func run() {
        let start = Date()
        do {
            result = try runQuery(text, ledger)
            failure = nil
        } catch {
            result = nil
            failure = error.localizedDescription
        }
        took = Date().timeIntervalSince(start)
    }

    private func csv(_ result: QueryResult) -> String {
        func cell(_ value: String) -> String {
            value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        return ([result.columns] + result.rows.map { $0.map(\.text) }).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private func copy(_ result: QueryResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(([result.columns] + result.rows.map { $0.map(\.text) }).map { $0.joined(separator: "\t") }.joined(separator: "\n"), forType: .string)
    }

    private func export(_ result: QueryResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "query.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv(result).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// a query's result: its columns as it named them, numbers on the right
private struct ResultTable: View {
    let result: QueryResult

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(result.columns.enumerated()), id: \.offset) { index, column in
                        Text(column).foregroundStyle(.secondary).gridColumnAlignment(numeric(index) ? .trailing : .leading)
                    }
                }
                Divider()
                ForEach(Array(result.rows.prefix(2000).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                            Text(value.text).monospacedDigit().lineLimit(1).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func numeric(_ index: Int) -> Bool { index < result.numeric.count && result.numeric[index] }
}
