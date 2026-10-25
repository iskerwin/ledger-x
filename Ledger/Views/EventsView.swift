import SwiftUI
import LedgerKit

struct EventsDest: Hashable {}
struct EventDest: Hashable { let tag: String }

/// an event to create (nil) or edit
struct EventEdit: Identifiable {
    let id = UUID()
    var event: LedgerEvent?
}

/// every event: the ongoing ones first
struct EventsView: View {
    @Environment(Store.self) var store
    @State private var editing: EventEdit?
    @State private var changing: LifeEventChange?
    @AppStorage(Store.autoEventsKey) private var auto = true

    var body: some View {
        List {
            if let L = store.L {
                let evs = ledgerEvents(L)
                let today = Day.today()
                let on = evs.filter { $0.ongoing(today) }
                let past = evs.filter { !$0.ongoing(today) }
                if evs.isEmpty {
                    Section {
                        EmptyAdd(text: LS("还没有事件。出差、旅行、装修、搬家……新建一个事件，期间记的每一笔会自动带上它的 #标签，事件页汇总一共花了多少。"), title: LS("新建事件")) { editing = EventEdit(event: nil) }
                    }
                }
                if !on.isEmpty { Section(LS("进行中")) { ForEach(on) { row($0, L) } } }
                if !past.isEmpty { Section(LS("已结束")) { ForEach(past) { row($0, L) } } }
                LifeEventsSections(changing: $changing)
                Section {
                    Toggle(LS("进行中的事件自动加到新记录"), isOn: $auto).tint(.jade)
                } footer: {
                    Text(LS("事件写在账本里：custom \"event\" \"标签\" \"名称\"，结束后加上最后一天。只用 #标签、没有写事件的，也按标签列在这里。"))
                }
            }
        }
        .refreshable { await store.refresh() }
        .listChanges(store.version)
        .navigationTitle(LS("事件"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = EventEdit(event: nil) } label: { Image(systemName: "plus") }.accessibilityLabel(LS("新建事件"))
            }
        }
        .sheet(item: $editing) { EventSheet(event: $0.event) }
        .sheet(item: $changing) { LifeEventSheet(type: $0.type) }
    }

    private func row(_ e: LedgerEvent, _ L: Ledger) -> some View {
        let s = eventSummary(L, e.tag, reimbursement: store.receivable)
        return NavigationLink(value: EventDest(tag: e.tag)) {
            HStack(spacing: AppSpacing.control) {
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    Text(e.title)
                    Text(eventDates(e) + " · " + LS("%@ 笔", s.txns.count)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Amount(n: s.total)
            }
        }
    }
}

func eventDates(_ e: LedgerEvent) -> String {
    e.start + " ~ " + (e.end ?? LS("进行中"))
}

/// one event: what it cost, by category, what is still to be reimbursed, and its transactions
struct EventDetailView: View {
    @Environment(Store.self) var store
    let tag: String
    @State private var exporting: ReimbExportTarget?
    @State private var editing: EventEdit?
    @State private var adding = false
    @State private var limit = 100

    var body: some View {
        List {
            if let L = store.L, let D = store.D, let e = ledgerEvents(L).first(where: { $0.tag == tag }) {
                let s = eventSummary(L, tag, reimbursement: D.receivable, openLinks: Set(D.openLinks.map { $0.link }))
                Section {
                    LabeledContent(LS("合计")) { Amount(n: s.total) }
                    LabeledContent(LS("自己的支出")) { Amount(n: s.spent) }
                    if s.advanced > 0.005 {
                        LabeledContent(LS("报销垫款")) { Amount(n: s.advanced) }
                        if s.unpaid > 0.005 {
                            LabeledContent(LS("其中未报销")) { Text(money(s.unpaid)).monospacedDigit().foregroundStyle(Color.warn).sensitive() }
                        }
                    }
                    if let f = s.first, let l = s.last {
                        let days = max(1, daysBetween(f, l) + 1)
                        LabeledContent(LS("日均（%@ 天）", days)) { Amount(n: s.total / Double(days)) }
                    }
                } header: {
                    Text(eventDates(e) + "  #" + tag).textCase(nil)
                }
                if !s.byCategory.isEmpty {
                    Section(LS("支出构成")) {
                        ForEach(s.byCategory, id: \.account) { c in
                            HStack(spacing: AppSpacing.control) {
                                Text(catLabel(c.account))
                                Spacer()
                                if s.spent > 0.005 {
                                    Text(String(format: "%.0f%%", c.amount / s.spent * 100)).font(.caption).foregroundStyle(.secondary)
                                }
                                Amount(n: c.amount)
                            }
                        }
                    }
                }
                Section {
                    if s.advanced > 0.005 {
                        Button { exporting = ReimbExportTarget(title: e.title, entries: s.txns) } label: { Label(LS("导出报销单…"), systemImage: "square.and.arrow.up").labelStyle(ControlLabelStyle()) }
                    }
                    if e.entry != nil {
                        Button { adding = true } label: { Label(LS("把这段时间的交易加入事件…"), systemImage: "calendar.badge.plus").labelStyle(ControlLabelStyle()) }
                        Button { editing = EventEdit(event: e) } label: { Label(e.end == nil ? LS("编辑 / 结束事件…") : LS("编辑事件…"), systemImage: "calendar.badge.clock").labelStyle(ControlLabelStyle()) }
                    } else {
                        Button { editing = EventEdit(event: e) } label: { Label(LS("写成事件…"), systemImage: "calendar.badge.plus").labelStyle(ControlLabelStyle()) }
                    }
                } footer: {
                    if e.entry == nil { Text(LS("这个标签还没有写成事件。写成事件后可以设置名称和日期，进行中时新记录自动带上标签。")) }
                }
                Section(LS("交易（%@ 笔）", s.txns.count)) {
                    ForEach(s.txns.prefix(limit), id: \.id) { t in
                        NavigationLink(value: TxDest(t)) { TxRow(t: t, showDate: true) }
                    }
                    if s.txns.count > limit { Button { limit += 200 } label: { Label(LS("显示更多"), systemImage: "chevron.down").labelStyle(ControlLabelStyle()) } }
                }
            } else {
                Text(LS("没有找到事件 #%@", tag)).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(store.L.flatMap { L in ledgerEvents(L).first { $0.tag == tag }?.title } ?? tag)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { EventSheet(event: $0.event) }
        .sheet(isPresented: $adding) { EventCandidatesSheet(tag: tag) }
        .sheet(item: $exporting) { ReimbExportSheet(target: $0) }
    }
}

/// create an event, rename it, change its days or end it
struct EventSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let event: LedgerEvent?
    @State private var title = ""
    @State private var tag = ""
    @State private var tagTouched = false
    @State private var start = Day.today()
    @State private var ended = false
    @State private var end = Day.today()
    @State private var ready = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L { form(L) } else { PageLoading() }
            }
            .keyboardDone()
            .navigationTitle(event?.entry == nil ? LS("新建事件") : LS("编辑事件"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } } }
        }
    }

    private var editingDirective: Bool { event?.entry != nil }

    private func text() -> String {
        let t = tag.trimmed
        guard isValidTag(t), !title.trimmed.isEmpty else { return "" }
        return eventLine(tag: t, title: title.trimmed, start: start, end: ended ? max(end, start) : nil)
    }

    private func form(_ L: Ledger) -> some View {
        let t = text()
        let taken = Set(ledgerEvents(L).map { $0.tag })
        let clash = !editingDirective && event == nil && taken.contains(tag.trimmed)
        return Form {
            Section {
                TextField(LS("名称，如 郑州出差"), text: Binding(get: { title }, set: { v in
                    title = v
                    if !tagTouched && event == nil { tag = eventTag(v, year: String(start.prefix(4)), taken: taken) }
                }))
                LabeledContent(LS("标签")) {
                    TextField("trip-2026", text: Binding(get: { tag }, set: { tag = $0; tagTouched = true }))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(event != nil)
                }
            } footer: {
                if !tag.isEmpty && !isValidTag(tag.trimmed) { Text(LS("标签只能包含英文字母、数字和 - _ / .")).foregroundStyle(Color.loss) }
                else if clash { Text(LS("这个标签已经有事件了")).foregroundStyle(Color.loss) }
                else { Text(LS("交易上记作 #%@", tag.trimmed)) }
            }
            Section {
                DatePicker(LS("开始"), selection: Binding(get: { Day.date(start) ?? Date() }, set: { start = Day.string($0) }), displayedComponents: .date)
                Toggle(LS("已结束"), isOn: $ended).tint(.jade)
                if ended {
                    DatePicker(LS("最后一天"), selection: Binding(get: { Day.date(end) ?? Date() }, set: { end = Day.string($0) }), displayedComponents: .date)
                }
            }
            Section(LS("将写入")) {
                if t.isEmpty { Text(LS("填写名称和标签后生成")).font(.footnote).foregroundStyle(.secondary) }
                else { MonoText(text: t) }
            }
            Section {
                Button {
                    Task { await save(L, t) }
                } label: {
                    HStack(spacing: AppSpacing.control) { Spacer(); BusyLabel(busy: saving, title: LS("保存"), systemImage: "checkmark").fontWeight(.semibold); Spacer() }
                }
                .primaryButton()
                .disabled(t.isEmpty || clash || saving)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            if let e = event {
                title = e.title == e.tag && e.entry == nil ? "" : e.title
                tag = e.tag
                tagTouched = true
                start = e.start
                if let x = e.end, e.entry != nil { ended = true; end = x }
                if e.entry == nil, let x = e.end { ended = x < Day.today(); end = x }
            }
        }
    }

    private func save(_ L: Ledger, _ t: String) async {
        guard !t.isEmpty else { return }
        saving = true
        defer { saving = false }
        let ops: [Op]
        if let e = event?.entry {
            var op = Op(kind: .replace, path: e.file)
            op.old = e.src
            op.text = t
            op.date = start
            op.label = LS("修改事件：%@", title.trimmed)
            op.summary = op.label
            ops = [op]
        } else {
            guard let o = store.makeOps(t, extra: OpExtra(label: LS("新建事件：%@", title.trimmed)), single: false) else { return }
            ops = o
        }
        guard let checked = await store.review(ops) else { return }
        dismiss()
        await store.commit(checked, word: LS("已保存事件"), checked: true)
    }
}

/// the transactions of the event's days that don't carry its tag: pick the ones that belong to it
struct EventCandidatesSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let tag: String
    @State private var picked: Set<Int> = []
    @State private var tagging = false
    @State private var ready = false

    var body: some View {
        NavigationStack {
            List {
                if let L = store.L, let e = ledgerEvents(L).first(where: { $0.tag == tag }) {
                    let cs = eventCandidates(L, e)
                    Section {
                        if cs.isEmpty { Text(LS("这段时间的交易都已经在事件里了")).foregroundStyle(.secondary) }
                        ForEach(cs, id: \.id) { t in
                            Button {
                                if picked.contains(t.id) { picked.remove(t.id) } else { picked.insert(t.id) }
                            } label: {
                                HStack(spacing: AppSpacing.icon) {
                                    Image(systemName: picked.contains(t.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(picked.contains(t.id) ? Color.jade : Color.secondary)
                                        .font(.title3)
                                    TxRow(t: t, showDate: true)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(picked.contains(t.id) ? .isSelected : [])
                        }
                    } header: {
                        HStack(spacing: AppSpacing.control) {
                            Text(eventDates(e) + LS(" · 已选 %@/%@", picked.count, cs.count)).textCase(nil)
                            Spacer()
                            Button {
                                picked = picked.count == cs.count ? [] : Set(cs.map { $0.id })
                            } label: { Label(picked.count == cs.count ? LS("全不选") : LS("全选"), systemImage: picked.count == cs.count ? "circle" : "checkmark.circle").labelStyle(ControlLabelStyle()) }
                            .font(.footnote).textCase(nil)
                        }
                    } footer: {
                        Text(LS("选中的交易会在标题行末尾加上 #%@。转账不在列表里。", tag))
                    }
                    .onAppear {
                        guard !ready else { return }
                        ready = true
                        // reimbursable advances in those days are almost always the trip's
                        picked = Set(cs.filter { t in t.postings.contains { $0.account == store.receivable } }.map { $0.id })
                    }
                }
            }
            .navigationTitle(LS("加入事件"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) } }
                ToolbarItem(placement: .confirmationAction) { Button { tagging = true } label: { Label(LS("下一步"), systemImage: "arrow.right").labelStyle(ControlLabelStyle()) }.disabled(picked.isEmpty) }
            }
            .sheet(isPresented: $tagging) {
                if let L = store.L {
                    BatchEditSheet(entries: L.txns.filter { picked.contains($0.id) }, mode: .tag, done: { dismiss() }, initialWord: tag)
                }
            }
        }
    }
}

/// ongoing events on the overview
struct EventsOverviewSection: View {
    @Environment(Store.self) var store
    let L: Ledger
    var body: some View {
        let on = ledgerEvents(L).filter { $0.entry != nil && $0.ongoing() }
        if !on.isEmpty {
            Section {
                ForEach(on) { e in
                    let s = eventSummary(L, e.tag, reimbursement: store.receivable)
                    NavigationLink(value: EventDest(tag: e.tag)) {
                        HStack(spacing: AppSpacing.control) {
                            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                Text(e.title)
                                Text(LS("%@ 起 · %@ 笔", e.start, s.txns.count)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Amount(n: s.total)
                        }
                    }
                }
            } header: {
                HStack(spacing: AppSpacing.control) {
                    Text(LS("进行中的事件"))
                    Spacer()
                    NavigationLink(value: EventsDest()) { Label(LS("全部"), systemImage: "list.bullet").labelStyle(ControlLabelStyle()).font(.footnote) }
                }
            }
        }
    }
}

/// unusual spending on the overview: the latest few, each can be dismissed
struct AlertsOverviewSection: View {
    @Environment(Store.self) var store
    var body: some View {
        let _ = store.alertsVersion
        let list = store.anomalyList
        if !list.isEmpty {
            Section {
                ForEach(list.prefix(3)) { a in AnomalyRow(a: a) }
                    .onAppear { store.markAlertsSeen() }
                if list.count > 3 {
                    NavigationLink(value: AlertsDest()) { Label(LS("全部 %@ 条", list.count), systemImage: "list.bullet").labelStyle(ControlLabelStyle()) }
                }
            } header: {
                HStack(spacing: AppSpacing.control) {
                    Text(LS("值得留意"))
                    Spacer()
                    NavigationLink(value: AlertsDest()) { Image(systemName: "slider.horizontal.3").font(.footnote) }
                }
            } footer: {
                // how it works, until the first one has been checked
                if store.confirmedAlertIDs.isEmpty {
                    Text(LS("点开核对，没问题就标记「核对无误」（也可左滑），只清除这一条提示，不影响以后的检查。"))
                }
            }
        }
    }
}

struct AlertsDest: Hashable {}

struct AnomalyDest: Hashable { let id: String }

/// one alert in a list: opens what it is about; swipe to mark it checked
struct AnomalyRow: View {
    @Environment(Store.self) var store
    let a: Anomaly
    var confirmed = false
    var body: some View {
        NavigationLink(value: AnomalyDest(id: a.id)) { AnomalyLabel(a: a, confirmed: confirmed) }
            .rowActions {
                if confirmed {
                    Button { store.unconfirmAlert(a.id) } label: { Label(LS("重新核对"), systemImage: "arrow.clockwise") }.tint(Color.warn)
                } else {
                    Button { store.confirmAlert(a.id) } label: { Label(LS("核对无误"), systemImage: "checkmark.seal") }.tint(Color.jade)
                }
            }
    }
}

struct AnomalyLabel: View {
    let a: Anomaly
    var confirmed = false
    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.icon) {
            Image(systemName: confirmed ? "checkmark.circle.fill" : anomalyIcon(a.kind))
                .foregroundStyle(confirmed ? Color.gain : Color.warn).frame(width: 22)
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                Text(a.title).lineLimit(1)
                Text(a.detail).font(.caption).foregroundStyle(.secondary).sensitive()
            }
        }
    }
}

func anomalyIcon(_ k: Anomaly.Kind) -> String {
    switch k {
    case .duplicate: return "doc.on.doc"
    case .large: return "exclamationmark.circle"
    case .category: return "chart.line.uptrend.xyaxis"
    case .subscription: return "arrow.triangle.2.circlepath"
    }
}

/// one alert: what to check, the transactions behind it, and the verdict
struct AnomalyDetailView: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    let id: String

    var body: some View {
        let _ = store.alertsVersion
        List {
            if let a = store.allAnomalies.first(where: { $0.id == id }), let L = store.L {
                let ok = store.confirmedAlertIDs.contains(a.id)
                Section {
                    AnomalyLabel(a: a, confirmed: ok)
                } footer: {
                    Text(hint(a.kind))
                }
                let ts = entries(a, L)
                if !ts.isEmpty {
                    Section(LS("相关交易（%@ 笔）", ts.count)) {
                        ForEach(ts, id: \.id) { t in NavigationLink(value: TxDest(t)) { TxRow(t: t, showDate: true) } }
                    }
                }
                if a.kind == .subscription {
                    Section { NavigationLink(value: SubscriptionsDest()) { Label(LS("打开订阅管理"), systemImage: "repeat").labelStyle(ControlLabelStyle()) } }
                }
                Section {
                    if ok {
                        Label(LS("已核对无误"), systemImage: "checkmark.seal").labelStyle(ControlLabelStyle()).foregroundStyle(Color.gain)
                        Button { store.unconfirmAlert(a.id) } label: { Label(LS("重新核对"), systemImage: "arrow.clockwise").labelStyle(ControlLabelStyle()) }
                    } else {
                        Button {
                            store.confirmAlert(a.id)
                            dismiss()
                        } label: {
                            HStack(spacing: AppSpacing.icon) {
                                Spacer(minLength: 0)
                                Image(systemName: "checkmark.circle")
                                Text(LS("核对无误")).fontWeight(.semibold)
                                Spacer(minLength: 0)
                            }
                        }
                        .primaryButton()
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    }
                } footer: {
                    Text(ok ? LS("这条已标记为核对无误，不再提示。") : LS("确认记录没有问题后点「核对无误」，只清除这一条提示，不影响以后的检查。有问题就点开交易修改或删除，改好后提示会自己消失。"))
                }
            } else {
                Label(LS("这条提示已经不存在了：相关记录改过，或已超过 30 天。"), systemImage: "checkmark.seal").labelStyle(ControlLabelStyle()).foregroundStyle(Color.gain)
            }
        }
        .navigationTitle(LS("核对"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// the transactions to look at: the alert's own, or this month's in the category
    private func entries(_ a: Anomaly, _ L: Ledger) -> [Entry] {
        if a.kind == .category, let cat = a.subject {
            let m = Day.ym(a.date)
            return L.txns.filter { Day.ym($0.date) == m && $0.postings.contains { catOf($0.account) == cat } }.reversed()
        }
        return a.entries
    }

    private func hint(_ k: Anomaly.Kind) -> String {
        switch k {
        case .duplicate: return LS("同一天、同一收付款方、金额完全相同的记录不止一笔。对照账单：真的买了两次就核对无误；记重了就删掉多余的那笔。")
        case .large: return LS("单笔金额超过设定的大额。确认金额、科目和付款账户没记错。")
        case .category: return LS("本月这一类的支出明显高于近 6 个月的平均。看看下面的交易里有没有记错科目或金额的。")
        case .subscription: return LS("订阅的扣费金额和设定的不一样，或者停用后仍在扣费。确认是调价就去订阅管理里更新金额。")
        }
    }
}

/// every alert, and how large a single expense has to be to count
struct AlertsView: View {
    @Environment(Store.self) var store

    var body: some View {
        let _ = store.alertsVersion
        let list = store.anomalyList
        List {
            Section {
                if list.isEmpty { Label(LS("近 30 天没有发现异常"), systemImage: "checkmark.seal").labelStyle(ControlLabelStyle()).foregroundStyle(Color.gain) }
                ForEach(list) { a in AnomalyRow(a: a) }
            } footer: {
                Text(LS("检查近 30 天：完全相同的重复记录、单笔大额支出、本月某类支出明显高于近 6 个月平均、订阅调价或停用后仍扣费。点开核对，没问题就标记「核对无误」。"))
            }
            let done = store.confirmedAnomalies
            if !done.isEmpty {
                Section(LS("已核对无误")) {
                    ForEach(done) { a in AnomalyRow(a: a, confirmed: true) }
                }
            }
            Section {
                Picker(LS("大额支出"), selection: Binding(get: { store.largeExpense }, set: { v in Task { await store.setLargeExpense(v) } })) {
                    Text(LS("不提醒")).tag(0.0)
                    ForEach([500.0, 1000, 2000, 5000, 10000], id: \.self) { Text(money($0, "CNY", 0)).tag($0) }
                }
            }
        }
        .navigationTitle(LS("值得留意"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.markAlertsSeen() }
    }
}

/// a new value to record for one of Beancount's events (nil type: choose one)
struct LifeEventChange: Identifiable {
    let id = UUID()
    var type: String?
}

/// Beancount's own event directives (`event "location" "深圳"`): each type a timeline, the current value on top
struct LifeEventsSections: View {
    @Environment(Store.self) var store
    @Binding var changing: LifeEventChange?
    var body: some View {
        if let L = store.L {
            let types = lifeEvents(L)
            ForEach(types) { t in
                Section {
                    ForEach(t.spans) { sp in
                        HStack(spacing: AppSpacing.control) {
                            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                Text(sp.value).fontWeight(sp.end == nil ? .semibold : .regular)
                                Text(sp.start + " ~ " + (sp.end ?? LS("至今"))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if sp.end == nil { Text(LS("当前")).font(.caption).foregroundStyle(Color.jade) }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { Task { _ = await store.deleteDirective(sp.entry, summary: "event \(t.type)") } } label: { Label(LS("删除"), systemImage: "trash") }
                        }
                        .contextMenu {
                            Button(role: .destructive) { Task { _ = await store.deleteDirective(sp.entry, summary: "event \(t.type)") } } label: { Label(LS("删除这一条"), systemImage: "trash") }
                        }
                    }
                    Button { changing = LifeEventChange(type: t.type) } label: { Label(LS("记一条变化…"), systemImage: "plus").labelStyle(ControlLabelStyle()) }
                } header: {
                    Text(t.type).textCase(nil)
                }
            }
            Section {
                Button { changing = LifeEventChange(type: nil) } label: { Label(types.isEmpty ? LS("记录常住地、雇主等变化…") : LS("新的类型…"), systemImage: "clock.arrow.circlepath").labelStyle(ControlLabelStyle()) }
            } footer: {
                Text(LS("Beancount 的 event 指令记录随时间变化的情况：event \"location\" \"深圳\"。每个值从写下的日期起，到下一次变化为止。"))
            }
        }
    }
}
