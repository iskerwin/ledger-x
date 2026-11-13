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

/// BQL against the ledger, as Fava's 查询: the built-in queries, the ledger's own and the last ones run on the left, the
/// text, ⌘↩ to run it away from the window, and the whole result on a table that sorts by any column
struct QueryPage: View {
    let ledger: Ledger
    let folder: URL
    @AppStorage("queryText") private var text = builtinQueries.first?.text ?? ""
    /// the last queries run, the latest first, as JSON
    @AppStorage("queryHistory") private var historyJSON = "[]"
    @State private var picked: String?
    @State private var result: QueryResult?
    /// counts the results, for the table to know a new one
    @State private var generation = 0
    @State private var failure: String?
    @State private var took: Double = 0
    @State private var running: Task<Void, Never>?

    private static let kept = 20

    var body: some View {
        SplitPage(listWidth: 240) {
            ForEach([("内置", builtinQueries), ("账本", ledgerQueries), ("最近", recent)], id: \.0) { group in
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
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 140)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: 8) {
                    Button("运行", action: run)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                    if running != nil { ProgressView().controlSize(.small) }
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
                    ResultTable(result: result, generation: generation)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .onAppear { if result == nil && failure == nil { run() } }
        .onChange(of: ObjectIdentifier(ledger)) { if result != nil { run() } }
        .onDisappear { running?.cancel() }
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

    private var history: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(historyJSON.utf8))) ?? []
    }

    /// the last ones run that aren't among the queries above, each under its first line
    private var recent: [SavedQuery] {
        let named = Set((builtinQueries + ledgerQueries).map { $0.text.trimmed })
        return history.filter { !named.contains($0) }.map { query in
            let first = query.components(separatedBy: .newlines).first { !$0.trimmed.isEmpty } ?? query
            return SavedQuery(id: "recent:" + query, name: first.trimmed, text: query, source: "mine")
        }
    }

    private func remember(_ query: String) {
        let next = [query] + history.filter { $0 != query }
        if let data = try? JSONEncoder().encode(Array(next.prefix(Self.kept))) { historyJSON = String(decoding: data, as: UTF8.self) }
    }

    /// worked out away from the window, so a query over every posting doesn't hold it up; a newer run replaces it
    private func run() {
        let query = text.trimmed, ledger = ledger
        guard !query.isEmpty else { return }
        remember(query)
        running?.cancel()
        running = Task {
            let start = Date()
            let outcome = await Task.detached { Result { try runQuery(query, ledger) } }.value
            guard !Task.isCancelled else { return }
            took = Date().timeIntervalSince(start)
            switch outcome {
            case .success(let found):
                result = found
                generation += 1
                failure = nil
            case .failure(let error):
                result = nil
                failure = error.localizedDescription
            }
            running = nil
        }
    }

    private func csv(_ result: QueryResult) -> String {
        func cell(_ value: String) -> String {
            value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        return ([result.columns] + result.rows.map { $0.map(\.text) }).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private func copy(_ result: QueryResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ResultTable.tabbed([result.columns] + result.rows.map { $0.map(\.text) }), forType: .string)
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

/// a query's result on an AppKit table: its columns as it named them, numbers on the right, only the rows in sight drawn
/// however many there are; a click on a column's title sorts by it, and ⌘C copies the rows picked
private struct ResultTable: NSViewRepresentable {
    let result: QueryResult
    let generation: Int

    static func tabbed(_ lines: [[String]]) -> String { lines.map { $0.joined(separator: "\t") }.joined(separator: "\n") }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = CopyingTable()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.copying = { [weak coordinator = context.coordinator] in coordinator?.copyPicked() }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.show(result, generation: generation)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        private var result = QueryResult(columns: [], rows: [], numeric: [])
        /// as sorted
        private var rows: [[QValue]] = []
        private var generation: Int?

        private static let cellID = NSUserInterfaceItemIdentifier("cell")
        private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        func show(_ result: QueryResult, generation: Int) {
            guard generation != self.generation, let table else { return }
            self.generation = generation
            self.result = result
            rows = result.rows
            for column in table.tableColumns { table.removeTableColumn(column) }
            for (index, name) in result.columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
                column.title = name
                column.headerCell.alignment = numeric(index) ? .right : .left
                column.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: !numeric(index))
                column.minWidth = 40
                column.width = width(index)
                table.addTableColumn(column)
            }
            table.sortDescriptors = []
            table.reloadData()
            table.scrollRowToVisible(0)
        }

        private func numeric(_ index: Int) -> Bool { index < result.numeric.count && result.numeric[index] }

        /// as wide as its title and the longest of the first rows, within reason
        private func width(_ index: Int) -> CGFloat {
            let texts = [result.columns[index]] + result.rows.prefix(300).map { index < $0.count ? $0[index].text : "" }
            let widest = texts.map { ($0 as NSString).size(withAttributes: [.font: Self.font]).width }.max() ?? 0
            return min(max(widest + 20, 60), 420)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = Int(tableColumn.identifier.rawValue) else { return nil }
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = Self.cellID
                let field = NSTextField(labelWithString: "")
                field.font = Self.font
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            let values = rows[row]
            cell.textField?.stringValue = index < values.count ? values[index].text : ""
            cell.textField?.alignment = numeric(index) ? .right : .left
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            if let order = tableView.sortDescriptors.first, let key = order.key, let index = Int(key) {
                rows = result.rows(sortedBy: index, ascending: order.ascending)
            } else {
                rows = result.rows
            }
            tableView.reloadData()
        }

        /// the rows picked, as they show; with none picked, the whole result under its titles
        func copyPicked() {
            guard let table else { return }
            let picked = table.selectedRowIndexes.map { rows[$0].map(\.text) }
            let lines = picked.isEmpty ? [result.columns] + rows.map { $0.map(\.text) } : picked
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ResultTable.tabbed(lines), forType: .string)
        }
    }
}

/// a table that answers 编辑 → 拷贝 (⌘C)
private final class CopyingTable: NSTableView {
    var copying: (() -> Void)?

    @objc func copy(_ sender: Any?) { copying?() }
}

/// what didn't read cleanly, as Fava's 错误 page: each one and where it is; the one picked shows the lines around it, opens
/// its file, and has what puts it right when the app can
struct ErrorsPage: View {
    let ledger: Ledger
    let folder: URL
    @State private var picked = 0

    /// those the app can put right first, as on the phone
    private var errors: [LedgerError] { ledger.errors.filter { $0.fix != nil } + ledger.errors.filter { $0.fix == nil } }

    var body: some View {
        let errors = self.errors
        if errors.isEmpty {
            ContentUnavailableView("没有错误", systemImage: "checkmark.circle")
        } else {
            SplitPage(listWidth: 320) {
                ForEach(Array(errors.enumerated()), id: \.offset) { index, error in
                    PickRow(title: error.msg, caption: place(error), symbol: error.soft ? "exclamationmark.circle" : "xmark.octagon",
                            tint: error.soft ? Color.secondary : Color.loss, picked: picked == index) { picked = index }
                }
            } detail: {
                ErrorDetail(error: errors[min(picked, errors.count - 1)], folder: folder)
                    .id("\(ObjectIdentifier(ledger))|\(picked)")
            }
            .onChange(of: ObjectIdentifier(ledger)) { picked = 0 }
        }
    }
}

/// "2026.bean:12"
private func place(_ error: LedgerError) -> String {
    guard let file = error.file else { return "" }
    return (error.line ?? 0) > 0 ? "\(file):\(error.line!)" : file
}

private struct ErrorDetail: View {
    let error: LedgerError
    let folder: URL
    /// the lines around it, with their numbers
    @State private var lines: [(number: Int, text: String)] = []
    @State private var working = false
    @State private var failure: String?

    private static let around = 4

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(error.msg).font(.title3).textSelection(.enabled)
                if let file = error.file {
                    HStack(spacing: 8) {
                        Text(place(error)).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        if case .declareCommodity(let currency) = error.fix {
                            Button("补上声明") { declare(currency) }
                                .buttonStyle(.borderedProminent)
                                .disabled(working)
                        }
                        Button("打开文件") { EntryTasks.open(file: file, in: folder) }
                    }
                }
                if let failure {
                    Text(failure).foregroundStyle(Color.loss).textSelection(.enabled)
                }
                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lines, id: \.number) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(line.number)").foregroundStyle(.tertiary).frame(width: 44, alignment: .trailing)
                                Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled)
                            }
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.number == error.line ? Color.loss.opacity(0.12) : Color.clear)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(12)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            guard let file = error.file, let line = error.line, line > 0 else { return }
            let url = folder.appendingPathComponent(file)
            lines = await Task.detached {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
                let all = text.components(separatedBy: "\n")
                let shown = max(1, line - Self.around)...min(all.count, line + Self.around)
                return shown.isEmpty ? [] : shown.map { ($0, all[$0 - 1]) }
            }.value
        }
    }

    /// as the phone's 补上声明: on the writing path, refused if a file changed meanwhile; the folder's watcher reads it back
    private func declare(_ currency: String) {
        working = true
        let folder = folder, firstUsed = error.entry?.date
        Task {
            let outcome = await Task.detached { Result { try commitFolderSave(prepareFolderCommodity(currency, firstUsed: firstUsed, folder: folder).get(), folder: folder) } }.value
            if case .failure(let error) = outcome { failure = error.localizedDescription }
            working = false
        }
    }
}
