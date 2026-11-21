import SwiftUI
import LedgerKit

// The category icons, names, colours, order and hidden groups, changed here as on the phone: they are in the ledger's
// ledger-x.json ("categories"), so both show the same. Each change is one step of 编辑 › 撤销.

/// what a change to the category style writes: into ledger-x.json, as it is now (a change from the phone stays)
@MainActor
func saveCategoryStyle(folder: URL, _ name: String, _ change: (inout CategoryStyle) -> Void) throws {
    let save = try prepareFolderConfig(folder: folder) { $0.editCategories(change) }.get()
    try SaveUndo.commit(save, folder: folder, name: name)
}

/// a group whose icon, name, colour or place among the common ones is being changed
struct CategoryStyleTarget: Identifiable {
    let group: CategoryGroup
    var id: String { group.id }
}

/// one group: its icon, its name, its colour and whether it is among the common ones on the card
struct CategoryStyleEditor: View {
    let group: CategoryGroup
    let ledger: Ledger
    let folder: URL
    @Environment(\.categoryStyle) private var style
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var icon = ""
    @State private var tint: String?
    @State private var shown = true
    @State private var message = ""

    private var builtIn: String { categorySymbol(group.id, CategoryStyle()) }
    private var current: String { icon.isEmpty ? builtIn : icon }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: current)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(IconTint.color(tint) ?? categoryColor(ledger, group.id, CategoryStyle()), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                TextField(LS("名称"), text: $title, prompt: Text(categoryGroupTitle(group, ledger)))
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 10), spacing: 8) {
                    ForEach(CategoryStyle.symbols.filter(hasSymbol), id: \.self) { s in
                        Button { icon = s == builtIn ? "" : s } label: {
                            Image(systemName: s)
                                .font(.system(size: 15))
                                .frame(width: 36, height: 36)
                                .foregroundStyle(current == s ? Color.white : Color.primary)
                                .background(current == s ? Color.accentColor : Color.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(s)
                    }
                }
            }
            .frame(height: 180)
            HStack(spacing: 8) {
                swatch(nil)
                ForEach(CategoryStyle.colorNames, id: \.self) { swatch($0) }
            }
            Toggle(LS("在常用分类中显示"), isOn: $shown)
            HStack {
                Button(LS("恢复默认")) { title = ""; icon = ""; tint = nil; shown = true }
                Spacer()
                Button(LS("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(LS("保存")) { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            title = style.titles[group.id] ?? ""
            icon = style.icons[group.id] ?? ""
            tint = style.colors[group.id]
            shown = !style.hidden.contains(group.id)
        }
        .alert(message, isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) {}
    }

    /// a colour to pick, or the group's own (nil); the picked one ringed
    private func swatch(_ name: String?) -> some View {
        let on = tint == name
        return Button { tint = name } label: {
            Circle()
                .fill(IconTint.color(name) ?? categoryColor(ledger, group.id, CategoryStyle()))
                .frame(width: 22, height: 22)
                .overlay { Circle().strokeBorder(Color.primary, lineWidth: on ? 2 : 0).padding(-3) }
                .overlay { if name == nil { Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
        }
        .buttonStyle(.plain)
        .help(name.map(IconTint.title) ?? LS("默认"))
        .accessibilityLabel(name.map(IconTint.title) ?? LS("默认"))
    }

    private func save() {
        let id = group.id, name = title, symbol = icon, color = tint, hide = !shown
        // nothing changed here: nothing written
        guard (style.titles[id] ?? "") != name.trimmed || (style.icons[id] ?? "") != symbol || style.colors[id] != color
                || style.hidden.contains(id) != hide else { dismiss(); return }
        do {
            try saveCategoryStyle(folder: folder, LS("分类样式：%@", name.trimmed.isEmpty ? categoryGroupTitle(group, ledger) : name.trimmed)) { s in
                s.setTitle(id, name)
                s.setIcon(id, symbol)
                s.setColor(id, color)
                s.setHidden(id, hide)
            }
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}

/// 分类图标与排序: the groups of spending or income in the order the card shows them (drag to move), each one's icon,
/// name and whether it is among the common ones
struct CategoryStyleManager: View {
    let ledger: Ledger
    let derived: Derived
    let folder: URL
    @State var root: String
    @Environment(\.categoryStyle) private var style
    @Environment(\.dismiss) private var dismiss
    @State private var editing: CategoryStyleTarget?
    /// per root: the order dragged to, written on 完成 (one step of 撤销, not one per drag)
    @State private var sorted: [String: [String]] = [:]
    @State private var message = ""

    private func shownGroups() -> [CategoryGroup] {
        let all = orderedGroups(categoryGroups(derived, root: root), saved: style.order[root] ?? [])
        return sorted[root].map { orderedGroups(all, saved: $0) } ?? all
    }

    var body: some View {
        let groups = shownGroups()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(LS("分类图标与排序")).font(.headline)
                Spacer()
                Picker(LS("类型"), selection: $root) {
                    Text(LS("支出")).tag("Expenses:")
                    Text(LS("收入")).tag("Income:")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            List {
                ForEach(groups) { g in
                    HStack(spacing: 10) {
                        Image(systemName: categorySymbol(g.id, style))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(categoryColor(ledger, g.id, style), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(categoryTitle(g, ledger, style))
                            .foregroundStyle(style.hidden.contains(g.id) ? .secondary : .primary)
                        Spacer()
                        if style.hidden.contains(g.id) { Text(LS("已隐藏")).foregroundStyle(.secondary) }
                        Button(LS("编辑…")) { editing = CategoryStyleTarget(group: g) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = CategoryStyleTarget(group: g) }
                }
                .onMove { from, to in
                    var ids = groups.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    sorted[root] = ids
                }
            }
            .frame(minHeight: 320)
            HStack {
                Button(LS("恢复默认图标与名称")) {
                    let ids = groups.map(\.id)
                    write(LS("恢复默认分类图标与名称")) { $0.resetIconsAndNames(ids) }
                }
                Button(LS("按使用次数重新排序")) {
                    sorted[root] = categoryGroups(derived, root: root).map(\.id)
                }
                Spacer()
                Button(LS("完成")) { finish() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .sheet(item: $editing) { CategoryStyleEditor(group: $0.group, ledger: ledger, folder: folder) }
        .alert(message, isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) {}
    }

    /// the orders dragged to, both kinds in one step
    private func finish() {
        let changed = sorted.filter { $0.value != (style.order[$0.key] ?? []) }
        if !changed.isEmpty {
            write(LS("调整分类顺序")) { s in for (r, ids) in changed { s.setOrder(r, ids) } }
            guard message.isEmpty else { return }
        }
        dismiss()
    }

    private func write(_ name: String, _ change: (inout CategoryStyle) -> Void) {
        do { try saveCategoryStyle(folder: folder, name, change) } catch { message = error.localizedDescription }
    }
}
