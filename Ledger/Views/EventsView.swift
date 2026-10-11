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
    @EnvironmentObject var store: Store
    @State private var editing: EventEdit?
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
                        Text(LS("还没有事件。出差、旅行、装修、搬家……新建一个事件，期间记的每一笔会自动带上它的 #标签，事件页汇总一共花了多少。"))
                            .foregroundStyle(.secondary)
                    }
                }
                if !on.isEmpty { Section(LS("进行中")) { ForEach(on) { row($0, L) } } }
                if !past.isEmpty { Section(LS("已结束")) { ForEach(past) { row($0, L) } } }
                Section {
                    Toggle(LS("进行中的事件自动加到新记录"), isOn: $auto).tint(.jade)
                } footer: {
                    Text(LS("事件写在账本里：custom \"event\" \"标签\" \"名称\"，结束后加上最后一天。只用 #标签、没有写事件的，也按标签列在这里。"))
                }
            }
        }
        .navigationTitle(LS("事件"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = EventEdit(event: nil) } label: { Image(systemName: "plus") }.accessibilityLabel(LS("新建事件"))
            }
        }
        .sheet(item: $editing) { EventSheet(event: $0.event) }
    }

    private func row(_ e: LedgerEvent, _ L: Ledger) -> some View {
        let s = eventSummary(L, e.tag, reimbursement: store.receivable)
        return NavigationLink(value: EventDest(tag: e.tag)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
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
    @EnvironmentObject var store: Store
    let tag: String
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
                            HStack {
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
                    if e.entry != nil {
                        Button(LS("把这段时间的交易加入事件…")) { adding = true }
                        Button(e.end == nil ? LS("编辑 / 结束事件…") : LS("编辑事件…")) { editing = EventEdit(event: e) }
                    } else {
                        Button(LS("写成事件…")) { editing = EventEdit(event: e) }
                    }
                } footer: {
                    if e.entry == nil { Text(LS("这个标签还没有写成事件。写成事件后可以设置名称和日期，进行中时新记录自动带上标签。")) }
                }
                Section(LS("交易（%@ 笔）", s.txns.count)) {
                    ForEach(s.txns.prefix(limit), id: \.id) { t in
                        NavigationLink(value: TxDest(t)) { TxRow(t: t, showDate: true) }
                    }
                    if s.txns.count > limit { Button(LS("显示更多")) { limit += 200 } }
                }
            } else {
                Text(LS("没有找到事件 #%@", tag)).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(store.L.flatMap { L in ledgerEvents(L).first { $0.tag == tag }?.title } ?? tag)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { EventSheet(event: $0.event) }
        .sheet(isPresented: $adding) { EventCandidatesSheet(tag: tag) }
    }
}

/// create an event, rename it, change its days or end it
struct EventSheet: View {
    @EnvironmentObject var store: Store
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
                if let L = store.L { form(L) } else { ProgressView() }
            }
            .keyboardDone()
            .navigationTitle(event?.entry == nil ? LS("新建事件") : LS("编辑事件"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } } }
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
                    HStack { Spacer(); if saving { ProgressView() } else { Text(LS("保存")).fontWeight(.semibold) }; Spacer() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.jade)
                .controlSize(.large)
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
    @EnvironmentObject var store: Store
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
                                HStack(spacing: 10) {
                                    Image(systemName: picked.contains(t.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(picked.contains(t.id) ? Color.jade : Color.secondary)
                                        .font(.title3)
                                    TxRow(t: t, showDate: true)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(eventDates(e) + LS(" · 已选 %@/%@", picked.count, cs.count)).textCase(nil)
                            Spacer()
                            Button(picked.count == cs.count ? LS("全不选") : LS("全选")) {
                                picked = picked.count == cs.count ? [] : Set(cs.map { $0.id })
                            }
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
                ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(LS("下一步")) { tagging = true }.disabled(picked.isEmpty) }
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
    @EnvironmentObject var store: Store
    let L: Ledger
    var body: some View {
        let on = ledgerEvents(L).filter { $0.entry != nil && $0.ongoing() }
        if !on.isEmpty {
            Section {
                ForEach(on) { e in
                    let s = eventSummary(L, e.tag, reimbursement: store.receivable)
                    NavigationLink(value: EventDest(tag: e.tag)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title)
                                Text(LS("%@ 起 · %@ 笔", e.start, s.txns.count)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Amount(n: s.total)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(LS("进行中的事件"))
                    Spacer()
                    NavigationLink(value: EventsDest()) { Text(LS("全部")).font(.footnote) }
                }
            }
        }
    }
}

/// unusual spending on the overview: the latest few, each can be dismissed
struct AlertsOverviewSection: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let _ = store.alertsVersion
        let list = store.anomalyList
        if !list.isEmpty {
            Section {
                ForEach(list.prefix(3)) { a in AnomalyRow(a: a) }
                    .onAppear { store.markAlertsSeen() }
                if list.count > 3 {
                    NavigationLink(value: AlertsDest()) { Text(LS("全部 %@ 条", list.count)) }
                }
            } header: {
                HStack {
                    Text(LS("值得留意"))
                    Spacer()
                    NavigationLink(value: AlertsDest()) { Image(systemName: "slider.horizontal.3").font(.footnote) }
                }
            }
        }
    }
}

struct AlertsDest: Hashable {}

struct AnomalyRow: View {
    @EnvironmentObject var store: Store
    let a: Anomaly
    var body: some View {
        Group {
            if a.entries.count == 1, let t = a.entries.first {
                NavigationLink(value: TxDest(t)) { label }
            } else if a.kind == .duplicate, let t = a.entries.first {
                NavigationLink(value: TxDest(t)) { label }
            } else if a.kind == .subscription {
                NavigationLink(value: SubscriptionsDest()) { label }
            } else {
                label
            }
        }
        .swipeActions {
            Button(LS("忽略")) { store.dismissAlert(a.id) }.tint(.gray)
        }
        .contextMenu {
            Button(LS("忽略")) { store.dismissAlert(a.id) }
        }
    }

    private var label: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.warn).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).lineLimit(1)
                Text(a.detail).font(.caption).foregroundStyle(.secondary).sensitive()
            }
        }
    }

    private var icon: String {
        switch a.kind {
        case .duplicate: return "doc.on.doc"
        case .large: return "exclamationmark.circle"
        case .category: return "chart.line.uptrend.xyaxis"
        case .subscription: return "arrow.triangle.2.circlepath"
        }
    }
}

/// every alert, and how large a single expense has to be to count
struct AlertsView: View {
    @EnvironmentObject var store: Store
    @AppStorage(Store.largeKey) private var large = 2000.0

    var body: some View {
        let _ = store.alertsVersion
        let list = store.anomalyList
        List {
            Section {
                if list.isEmpty { Label(LS("近 30 天没有发现异常"), systemImage: "checkmark.seal").foregroundStyle(Color.gain) }
                ForEach(list) { a in AnomalyRow(a: a) }
            } footer: {
                Text(LS("检查近 30 天：完全相同的重复记录、单笔大额支出、本月某类支出明显高于近 6 个月平均、订阅调价或停用后仍扣费。左滑忽略。"))
            }
            Section {
                Picker(LS("大额支出"), selection: $large) {
                    Text(LS("不提醒")).tag(0.0)
                    ForEach([500.0, 1000, 2000, 5000, 10000], id: \.self) { Text(money($0, "CNY", 0)).tag($0) }
                }
                if !store.dismissedAlerts.isEmpty {
                    Button(LS("恢复已忽略的 %@ 条", store.dismissedAlerts.count)) { store.restoreAlerts() }
                }
            }
        }
        .navigationTitle(LS("值得留意"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.markAlertsSeen() }
        .onChange(of: large) { _, _ in store.objectWillChange.send() }
    }
}
