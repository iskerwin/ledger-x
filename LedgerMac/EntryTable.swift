import SwiftUI
import AppKit
import LedgerKit

/// a line of the table's right-click menu; one with nothing to run is a divider
struct TableMenuItem {
    let title: String
    var enabled = true
    let run: (() -> Void)?

    static let divider = TableMenuItem(title: "", run: nil)
}

/// the journal's rows on an AppKit table: only the rows in sight are drawn, so a ledger of any length scrolls as one of
/// a hundred entries. Each row is still our own SwiftUI row; the one picked alone opens with its source on a row of its
/// own under it. Picking, ↑ ↓, ⌘ and ⇧ clicks are the table's own; a click on the one picked puts it away, as Esc does
struct EntryTable: NSViewRepresentable {
    let lines: [JournalRow]
    /// changes when what the rows show does (a new list, the columns, their widths), so the rows in sight are drawn again
    let look: AnyHashable
    @Binding var selected: Set<String>
    let row: (_ line: JournalRow, _ index: Int, _ picked: Bool) -> AnyView
    let panel: (JournalRow) -> AnyView
    let menu: (_ chosen: [JournalRow]) -> [TableMenuItem]
    /// ↩ on what's picked
    let open: () -> Void
    /// ⌫ on what's picked
    let delete: () -> Void
    /// takes the keys when it first shows
    let focus: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyedTable()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = true
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        table.takesFocus = focus
        table.coordinator = context.coordinator
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: KeyedTable?
        private(set) var parent: EntryTable?
        private var lines: [JournalRow] = []
        /// each line's place in `lines`
        private var position: [String: Int] = [:]
        private var look: AnyHashable?
        /// what's picked as the table has it, drawn from before the page hears of it
        private var chosen = Set<String>()
        /// the line open under itself, by its place
        private var opened: Int?
        /// the open line's source, kept while it stays open so what's typed in it lives through the rows being drawn again
        private var panelHost: NSHostingView<AnyView>?
        private var panelID: String?
        /// set while the table's picking is set from here, so it isn't read back as the user's
        private var syncing = false

        private static let rowID = NSUserInterfaceItemIdentifier("entryRow")

        func update(_ parent: EntryTable) {
            self.parent = parent
            guard let table else { return }
            if parent.look != look {
                look = parent.look
                lines = parent.lines
                position = Dictionary(lines.enumerated().map { ($1.id, $0) }) { first, _ in first }
                chosen = parent.selected.filter { position[$0] != nil }
                opened = openedLine(chosen)
                syncing = true
                table.reloadData()
                table.selectRowIndexes(rows(for: chosen), byExtendingSelection: false)
                syncing = false
            } else if parent.selected != chosen {
                // put away from the page: Esc in a sheet, a filter that took the rows away
                pick(parent.selected.filter { position[$0] != nil })
            } else if let opened, let panelHost {
                panelHost.rootView = parent.panel(lines[opened])
            }
        }

        // MARK: rows and lines

        func numberOfRows(in tableView: NSTableView) -> Int { lines.count + (opened == nil ? 0 : 1) }

        /// the line on a row of the table; nil for the source under the open one
        func line(at row: Int) -> Int? {
            guard let opened, row > opened else { return row }
            return row == opened + 1 ? nil : row - 1
        }

        private func row(of line: Int) -> Int {
            guard let opened, line > opened else { return line }
            return line + 1
        }

        private func rows(for ids: Set<String>) -> IndexSet {
            IndexSet(ids.compactMap { position[$0] }.map(row(of:)))
        }

        private func openedLine(_ ids: Set<String>) -> Int? {
            ids.count == 1 ? ids.first.flatMap { position[$0] } : nil
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let parent else { return nil }
            guard let index = line(at: row) else { return panelView(parent) }
            let line = lines[index]
            let host: NSHostingView<AnyView>
            if let reused = tableView.makeView(withIdentifier: Self.rowID, owner: nil) as? NSHostingView<AnyView> {
                host = reused
                host.rootView = parent.row(line, index, chosen.contains(line.id))
            } else {
                host = NSHostingView(rootView: parent.row(line, index, chosen.contains(line.id)))
                host.identifier = Self.rowID
            }
            return host
        }

        private func panelView(_ parent: EntryTable) -> NSView? {
            guard let opened else { return nil }
            let line = lines[opened]
            if let panelHost, panelID == line.id {
                panelHost.rootView = parent.panel(line)
                return panelHost
            }
            let host = NSHostingView(rootView: parent.panel(line))
            panelHost = host
            panelID = line.id
            return host
        }

        // MARK: picking

        func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
            // the source under the open line isn't a line to pick
            guard let opened else { return proposed }
            var picked = proposed
            picked.remove(opened + 1)
            return picked
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap(line(at:)).map { lines[$0].id })
            guard ids != chosen else { return }
            pick(ids)
            parent?.selected = ids
        }

        /// draws again the lines picked or put away, and moves the source under the one picked alone
        private func pick(_ ids: Set<String>) {
            guard let table else { return }
            let changed = chosen.symmetricDifference(ids).compactMap { position[$0] }
            chosen = ids
            let next = openedLine(ids)
            syncing = true
            if next != opened {
                table.beginUpdates()
                if let opened { table.removeRows(at: [opened + 1], withAnimation: []) }
                opened = next
                if let next { table.insertRows(at: [next + 1], withAnimation: []) }
                table.endUpdates()
            }
            if next == nil {
                panelHost = nil
                panelID = nil
            }
            table.selectRowIndexes(rows(for: ids), byExtendingSelection: false)
            let redrawn = IndexSet(changed.map(row(of:)))
            table.reloadData(forRowIndexes: redrawn, columnIndexes: [0])
            table.noteHeightOfRows(withIndexesChanged: redrawn)
            if let next { table.scrollRowToVisible(row(of: next)) }
            syncing = false
        }

        func menu() -> NSMenu? {
            guard let parent, let table else { return nil }
            let picked = table.selectedRowIndexes.compactMap(line(at:)).map { lines[$0] }
            let items = parent.menu(picked)
            guard !items.isEmpty else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                guard let run = item.run else {
                    menu.addItem(.separator())
                    continue
                }
                let action = MenuAction(run)
                let entry = NSMenuItem(title: item.title, action: #selector(MenuAction.fire), keyEquivalent: "")
                entry.target = action
                entry.representedObject = action
                entry.isEnabled = item.enabled
                menu.addItem(entry)
            }
            return menu
        }
    }
}

/// the table, with the journal's keys: ↩ opens the form, ⌫ asks to delete, Esc puts the picking away
final class KeyedTable: NSTableView {
    weak var coordinator: EntryTable.Coordinator?
    var takesFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if takesFocus, let window {
            takesFocus = false
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: coordinator?.parent?.open()
        case 51, 117: coordinator?.parent?.delete()
        case 53: deselectAll(nil)
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        // a click on the one picked puts it away
        if row >= 0, selectedRowIndexes == [row], event.modifierFlags.intersection([.command, .shift]).isEmpty {
            deselectAll(nil)
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, coordinator?.line(at: row) != nil else { return nil }
        // a right-click outside what's picked is about that line alone
        if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return coordinator?.menu()
    }
}

/// a menu line's action, kept alive by the line
private final class MenuAction: NSObject {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func fire() { run() }
}

/// how the rows in sight look besides the list: the table draws them again when it changes
private struct TableLook: Hashable {
    let generation: Int
    let columns: [EntryColumn]
    let widths: [EntryColumn: CGFloat]
    let hidden: Bool
    let postings: Bool
}

/// entries under the names of their columns on the table: the amount keeps its width at the end, the one picked opens
/// in place, ↩ edits it, ⌫ deletes it, and a right-click has the rest
struct EntryList: View {
    let lines: [JournalRow]
    /// counts the lists worked out, for the table to know a new one
    let generation: Int
    /// what the account being looked through holds after each
    let balances: [ObjectIdentifier: Inventory]
    let widths: EntryWidths
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    @Binding var sortOrder: [KeyPathComparator<JournalRow>]
    @Binding var selected: Set<String>
    @Binding var tasks: EntryTasks
    var postings = false
    let focus: Bool
    @AppStorage("hideAmounts") private var hideAmounts = false
    /// the rows live in AppKit's table, out of this view's environment: handed on to them
    @Environment(\.filterTag) private var filterTag

    /// the one picked, open under its row; several picked have nothing single to show
    private var picked: Entry? {
        guard selected.count == 1, let id = selected.first else { return nil }
        return lines.first { $0.id == id }?.entry
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = widths.fit(EntryColumn.allCases, in: geometry.size.width)
            let columns = layout.columns
            VStack(spacing: 0) {
                EntryHeader(columns: columns, widths: layout.widths, sortOrder: $sortOrder)
                Divider()
                EntryTable(lines: lines,
                           look: TableLook(generation: generation, columns: columns, widths: layout.widths, hidden: hideAmounts, postings: postings),
                           selected: $selected,
                           row: { line, index, picked in
                               AnyView(EntryRow(line: line, ledger: ledger, columns: columns, widths: layout.widths, picked: picked,
                                                balance: balances[ObjectIdentifier(line.entry)], postings: postings)
                                   .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
                                   .environment(\.filterTag, filterTag))
                           },
                           panel: { line in AnyView(SourcePanel(entry: line.entry, ledger: ledger, config: config, folder: folder, tasks: $tasks)) },
                           menu: menu,
                           open: {
                               guard let entry = picked, entry.editable else { return }
                               tasks.edit(entry, ledger, config)
                           },
                           delete: { tasks.deleting = picked.flatMap { $0.editable ? $0 : nil } },
                           focus: focus)
            }
        }
    }

    private func menu(_ chosen: [JournalRow]) -> [TableMenuItem] {
        let entries = chosen.map(\.entry)
        guard entries.count == 1, let entry = entries.first else {
            return [TableMenuItem(title: "复制 \(entries.count) 笔原文") { EntryTasks.copy(entries) }]
        }
        return [TableMenuItem(title: "编辑…", enabled: entry.editable) { tasks.edit(entry, ledger, config) },
                TableMenuItem(title: "复制原文") { EntryTasks.copy(entries) },
                TableMenuItem(title: "打开所在文件") { EntryTasks.open(entry, in: folder) },
                .divider,
                TableMenuItem(title: "删除…", enabled: entry.editable) { tasks.deleting = entry }]
    }
}
