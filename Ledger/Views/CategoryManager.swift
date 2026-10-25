import SwiftUI
import LedgerKit

/// 科目管理 from the grid: the account manager for one root
struct CategoryAccountsDest: Hashable { let root: String }

/// a grid cell whose look is being changed
struct StyleTarget: Identifiable {
    let group: CategoryGroup
    var id: String { group.id }
}

/// 分类图标与排序: the 记一笔 grid's cells in order (drag to move), tap one for its icon, name and whether it shows.
/// Kept on this phone; the ledger is not changed.
struct CategoryManager: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    @State var root: String
    @State private var styling: StyleTarget?
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            List {
                if let L = store.L, let D = store.D {
                    Section {
                        Picker(LS("类型"), selection: $root) {
                            Text(LS("支出")).tag("Expenses:")
                            Text(LS("收入")).tag("Income:")
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                    Section {
                        NavigationLink(value: CategoryAccountsDest(root: root == "Income:" ? "Income" : "Expenses")) {
                            Label {
                                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                    Text(LS("科目管理"))
                                    Text(LS("新建、改名、合并、关闭%@科目", root == "Income:" ? LS("收入") : LS("支出"))).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "folder") }
                        }
                    }
                    let groups = store.allGroups(root, D)
                    let hidden = Set(store.catStyle.hidden)
                    Section {
                        ForEach(groups) { g in
                            Button { styling = StyleTarget(group: g) } label: {
                                HStack(spacing: AppSpacing.icon) {
                                    Image(systemName: store.catIcon(Store.cellKey(g)))
                                        .font(.system(size: 17))
                                        .frame(width: 36, height: 36)
                                        .background(Color(.tertiarySystemFill), in: Circle())
                                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                        Text(store.catTitle(g, L)).foregroundStyle(hidden.contains(g.id) ? Color.secondary : Color.primary)
                                        Text(g.single ? acctLabel(g.accounts[0]) : LS("%@ 个科目", g.accounts.count))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if hidden.contains(g.id) { Text(LS("已隐藏")).font(.caption).foregroundStyle(.secondary) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .onMove { from, to in
                            var ids = groups.map { $0.id }
                            ids.move(fromOffsets: from, toOffset: to)
                            store.catStyle.order[root] = ids
                        }
                    } footer: {
                        Text(LS("点「排序」后拖动调整宫格顺序；点按一项更换图标、改名或隐藏。这些设置只存在本机，不改动账本；隐藏的分类仍可在完整表单里选择。"))
                    }
                    Section {
                        Button {
                            var s = store.catStyle
                            for g in groups {
                                s.icons[g.id] = nil
                                for a in g.accounts { s.icons[a] = nil }
                                s.titles[g.id] = nil
                            }
                            s.hidden.removeAll { id in groups.contains { $0.id == id } }
                            store.catStyle = s
                        } label: { Label(LS("恢复默认图标与名称"), systemImage: "arrow.counterclockwise").labelStyle(ControlLabelStyle()) }
                        Button {
                            store.catStyle.order[root] = categoryGroups(D, root: root).map { $0.id }
                        } label: { Label(LS("按使用次数重新排序"), systemImage: "arrow.up.arrow.down").labelStyle(ControlLabelStyle()) }
                    }
                }
            }
            // sorting is its own mode: with the handles always out, a tap on a row may not reach its button
            .environment(\.editMode, $editMode)
            .navigationTitle(LS("分类图标与排序"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { withAnimation(AppMotion.standard) { editMode = editMode.isEditing ? .inactive : .active } } label: { Label(editMode.isEditing ? LS("排好了") : LS("排序"), systemImage: editMode.isEditing ? "checkmark" : "arrow.up.arrow.down").labelStyle(ControlLabelStyle()) }
                }
                ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }.fontWeight(.semibold) }
            }
            .sheet(item: $styling) { CategoryStyleSheet(target: $0).pickerSheet() }
            .navigationDestination(for: CategoryAccountsDest.self) { AccountManagerView(only: $0.root) }
            .navigationDestination(for: AccountEditDest.self) { AccountEditView(name: $0.name) }
        }
    }
}

/// one cell: its icon (from a set of symbols), its name and whether the grid shows it
struct CategoryStyleSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let target: StyleTarget
    @State private var title = ""
    @State private var icon = ""
    @State private var hidden = false

    private var key: String { Store.cellKey(target.group) }

    var body: some View {
        NavigationStack {
            Form {
                if let L = store.L {
                    Section {
                        HStack(spacing: AppSpacing.control) {
                            Spacer()
                            VStack(spacing: AppSpacing.icon) {
                                Image(systemName: icon.isEmpty ? store.catIcon(key) : icon)
                                    .font(.system(size: 26))
                                    .frame(width: 64, height: 64)
                                    .foregroundStyle(Color.onJade)
                                    .background(Color.jade, in: Circle())
                                Text(title.trimmed.isEmpty ? defaultTitle(L) : title).font(.subheadline)
                            }
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                    Section {
                        TextField(defaultTitle(L), text: $title)
                        Toggle(LS("在宫格中显示"), isOn: Binding(get: { !hidden }, set: { hidden = !$0 })).tint(.jade)
                    } footer: {
                        Text(target.group.accounts.map { acctLabel($0) }.joined(separator: "、"))
                    }
                    Section(LS("图标")) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.icon), count: 6), spacing: AppSpacing.control) {
                            ForEach(Self.symbols.filter { Symbols.valid($0) }, id: \.self) { s in
                                let on = (icon.isEmpty ? store.catIcon(key) : icon) == s
                                Button { icon = s } label: {
                                    Image(systemName: s)
                                        .font(.system(size: 18))
                                        .frame(width: 42, height: 42)
                                        .foregroundStyle(on ? Color.onJade : Color.primary)
                                        .background(on ? Color.jade : Color(.tertiarySystemFill), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(s)
                            }
                        }
                        .padding(.vertical, AppSpacing.icon)
                        Button { icon = Symbols.valid(defaultCategoryIcon(key)) ? defaultCategoryIcon(key) : "square.grid.2x2" } label: { Label(LS("恢复默认图标"), systemImage: "arrow.counterclockwise").labelStyle(ControlLabelStyle()) }
                    }
                }
            }
            .navigationTitle(LS("分类样式"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) { Button { save(); dismiss() } label: { SaveLabel() } }
            }
            .onAppear {
                title = store.catStyle.titles[target.group.id] ?? ""
                icon = store.catStyle.icons[key] ?? ""
                hidden = store.catStyle.hidden.contains(target.group.id)
            }
        }
    }

    private func defaultTitle(_ L: Ledger) -> String {
        store.defaultCatTitle(target.group, L)
    }

    private func save() {
        var s = store.catStyle
        let t = title.trimmed
        s.titles[target.group.id] = t.isEmpty ? nil : t
        // the built-in guess isn't stored, so a better guess in a later version still reaches it
        s.icons[key] = icon.isEmpty || icon == defaultCategoryIcon(key) ? nil : icon
        s.hidden.removeAll { $0 == target.group.id }
        if hidden { s.hidden.append(target.group.id) }
        store.catStyle = s
    }

    /// symbols to choose from (any this iOS lacks is left out when shown)
    static let symbols: [String] = [
        "fork.knife", "cup.and.saucer", "takeoutbag.and.cup.and.straw", "wineglass", "birthday.cake", "carrot",
        "cart", "basket", "bag", "tshirt", "handbag", "eyeglasses",
        "house", "key", "bolt", "drop", "flame", "sofa",
        "lightbulb", "hammer", "wrench.and.screwdriver", "paintbrush", "washer", "bed.double",
        "car", "fuelpump", "bus", "tram", "airplane", "bicycle",
        "road.lanes", "parkingsign", "shippingbox", "suitcase", "map", "ferry",
        "iphone", "desktopcomputer", "laptopcomputer", "headphones", "gamecontroller", "tv",
        "app.badge", "icloud", "antenna.radiowaves.left.and.right", "wifi", "music.note", "film",
        "book", "graduationcap", "pencil.and.ruler", "figure.run", "dumbbell", "sportscourt",
        "cross.case", "pills", "stethoscope", "heart", "hands.sparkles", "comb",
        "gift", "envelope", "person.2", "figure.2.and.child.holdinghands", "pawprint", "leaf",
        "creditcard", "banknote", "percent", "chart.line.uptrend.xyaxis", "chart.pie", "building.columns",
        "briefcase", "star", "ticket", "giftcard", "yensign.circle", "dollarsign.circle",
        "shield", "doc.text", "scissors", "sparkles", "smoke", "ellipsis.circle",
    ]
}

/// a group of accounts (Assets:Bank, Expenses:Food) whose icon is being changed from 管理账户
struct IconTarget: Identifiable { let group: String; var id: String { group } }

/// the icon of any account group, used wherever the group shows (grid, 管理账户, accounts, reports); kept on this phone
struct GroupIconSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let group: String
    @State private var icon = ""

    /// the built-in one, without what was picked
    private var builtIn: String {
        group.hasPrefix("Expenses") || group.hasPrefix("Income") ? defaultCategoryIcon(group) : AccountKind.of(group).symbol
    }

    static let accountSymbols = [
        "building.columns.fill", "creditcard.fill", "wallet.pass.fill", "banknote.fill", "chart.line.uptrend.xyaxis",
        "bitcoinsign", "tray.and.arrow.down.fill", "percent", "house.fill", "car.fill", "shield.fill", "person.2.fill",
        "yensign.circle.fill", "dollarsign.circle.fill", "lock.fill", "gift.fill", "briefcase.fill", "heart.fill",
    ]

    var body: some View {
        let color = store.groupIcon(group).color
        let current = icon.isEmpty ? store.groupIcon(group).symbol : icon
        let choices = (group.hasPrefix("Assets") || group.hasPrefix("Liabilities") ? Self.accountSymbols + CategoryStyleSheet.symbols
                       : CategoryStyleSheet.symbols + Self.accountSymbols)
            .filter { Symbols.valid($0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: AppSpacing.control) {
                        Spacer()
                        VStack(spacing: AppSpacing.icon) {
                            IconBadge(symbol: current, color: color, size: 56)
                            Text(leaf(group) + (acctZH(group).map { " · " + $0 } ?? "")).font(.subheadline)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.icon), count: 6), spacing: AppSpacing.control) {
                        ForEach(choices, id: \.self) { s in
                            Button { icon = s } label: {
                                Image(systemName: s).font(.system(size: 18)).frame(width: 42, height: 42)
                                    .foregroundStyle(current == s ? Color.white : Color.primary)
                                    .background(current == s ? color : Color(.tertiarySystemFill), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(s)
                        }
                    }
                    .padding(.vertical, AppSpacing.icon)
                    Button { icon = builtIn } label: { Label(LS("恢复默认图标"), systemImage: "arrow.counterclockwise").labelStyle(ControlLabelStyle()) }
                } footer: {
                    Text(LS("这个大类在记一笔、管理账户、账户页和报表里都用这个图标；只存在这台手机。"))
                }
            }
            .navigationTitle(LS("更换图标"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        var s = store.catStyle
                        s.icons[group] = icon.isEmpty || icon == builtIn ? nil : icon
                        store.catStyle = s
                        dismiss()
                    } label: { SaveLabel() }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { icon = store.catStyle.icons[group] ?? "" }
        }
    }
}
