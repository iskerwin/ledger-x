import SwiftUI
import LedgerKit

/// what the transactions should look like (to rank the related ones first)
struct SubHint {
    var payee: String
    var name: String
    var account: String
    var amount: Double

    init(payee: String, name: String, account: String, amount: Double) {
        self.payee = payee; self.name = name; self.account = account; self.amount = amount
    }
    init(_ s: Subscription) {
        payee = s.payee.isEmpty ? s.name : s.payee; name = s.name; account = s.account; amount = s.amount
    }
}

/// pick expense transactions to link: related ones first, searchable, sortable and grouped
struct TxPicker: View {
    @EnvironmentObject var store: Store
    let hint: SubHint
    /// already linked to this subscription
    let exclude: Set<Int>
    @Binding var picked: Set<Int>
    @State private var q = ""
    @State private var sort = Sort.related
    @State private var allTime = false
    @State private var onlyRelated = true

    enum Sort: String, CaseIterable, Identifiable {
        case related, payee, narration, date, amount
        var id: String { rawValue }
        var name: String {
            switch self {
            case .related: return LS("相关度")
            case .payee: return LS("按商户")
            case .narration: return LS("按说明")
            case .date: return LS("按日期")
            case .amount: return LS("按金额")
            }
        }
    }

    struct Item: Identifiable {
        let t: Entry
        let amount: Double
        let currency: String
        let account: String
        let score: Int
        let owner: String?
        var id: Int { t.id }
        var payee: String { t.payee.isEmpty ? (t.narration.isEmpty ? "—" : t.narration) : t.payee }
        var narration: String { t.narration.isEmpty ? "—" : t.narration }
    }

    var body: some View {
        let items = filtered()
        List {
            Section {
                Picker(LS("排序"), selection: $sort) { ForEach(Sort.allCases) { Text($0.name).tag($0) } }
                if q.trimmed.isEmpty { Toggle(LS("只看相关的交易"), isOn: $onlyRelated) }
                Toggle(LS("包含两年前的交易"), isOn: $allTime)
            } footer: {
                Text(LS("相关：同商户、同科目或金额相近（±30%）。搜索可输入商户、说明、科目、金额（如 21、>20）或日期（如 2025-06）。"))
            }
            if items.isEmpty {
                Text(LS("没有符合条件的交易")).foregroundStyle(.secondary)
            } else if sort == .payee || sort == .narration {
                ForEach(groups(items), id: \.key) { g in
                    Section {
                        ForEach(g.items) { row($0) }
                    } header: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(g.key).textCase(nil)
                                Text(LS("%@ 笔 · %@ ~ %@", g.items.count, g.items.map { $0.t.date }.min() ?? "", g.items.map { $0.t.date }.max() ?? ""))
                                    .font(.caption2).textCase(nil)
                            }
                            Spacer()
                            let all = g.items.allSatisfy { picked.contains($0.id) }
                            Button(all ? LS("取消全选") : LS("全选")) {
                                for i in g.items { if all { picked.remove(i.id) } else { picked.insert(i.id) } }
                            }
                            .font(.caption).textCase(nil)
                        }
                    }
                }
            } else {
                Section { ForEach(items) { row($0) } }
            }
        }
        .listSectionSpacing(.compact)
        .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: LS("商户、说明、金额、日期"))
        .safeAreaInset(edge: .bottom) { summary }
    }

    private func row(_ i: Item) -> some View {
        Button {
            if picked.contains(i.id) { picked.remove(i.id) } else { picked.insert(i.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: picked.contains(i.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.jade).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(i.payee + (i.t.payee.isEmpty || i.t.narration.isEmpty ? "" : " · " + i.t.narration)).lineLimit(1)
                    Text(i.t.date + " · " + acctLabel(i.account)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let o = i.owner {
                        Text(LS("已属于「%@」，选中会改到这个订阅", o)).font(.caption2).foregroundStyle(Color.warn)
                    }
                }
                Spacer()
                Text(money(i.amount, i.currency)).monospacedDigit().sensitive()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var summary: some View {
        let sel = picked.compactMap { id in store.L.flatMap { id < $0.txns.count ? $0.txns[id] : nil } }
        let total = sel.reduce(0.0) { s, t in s + (t.postings.first { $0.account.hasPrefix("Expenses:") }?.units ?? 0) }
        let dates = sel.map { $0.date }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(LS("已选 %@ 笔 · 合计 %@", sel.count, money(total))).font(.subheadline.weight(.semibold)).sensitive()
                if let a = dates.min(), let b = dates.max() { Text(a == b ? a : a + " ~ " + b).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if !picked.isEmpty { Button(LS("清除")) { picked.removeAll() }.font(.subheadline) }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func groups(_ items: [Item]) -> [(key: String, items: [Item])] {
        let by = Dictionary(grouping: items) { sort == .payee ? $0.payee : $0.narration }
        return by.map { (key: $0.key, items: $0.value.sorted { $0.t.date > $1.t.date }) }
            .sorted { a, b in
                // the group that looks most like the subscription first, then by name
                let sa = a.items.map { $0.score }.max() ?? 0, sb = b.items.map { $0.score }.max() ?? 0
                return sa != sb ? sa > sb : a.key.localizedStandardCompare(b.key) == .orderedAscending
            }
    }

    private func filtered() -> [Item] {
        guard let L = store.L else { return [] }
        let since = allTime ? "" : Day.shift(Day.today(), -760)
        var owners: [String: String] = [:]
        for s in store.subs where s.name != hint.name { owners[s.link] = s.name }
        let query = q.trimmed.lowercased()
        var out: [Item] = []
        for t in L.txns.reversed() where !t.synthetic && t.date >= since && !exclude.contains(t.id) {
            guard let p = t.postings.first(where: { $0.account.hasPrefix("Expenses:") }), let u = p.units, let c = p.currency else { continue }
            let payee = t.payee.isEmpty ? t.narration : t.payee
            var score = 0
            if !hint.payee.isEmpty && (payee == hint.payee || payee.contains(hint.payee) || hint.payee.contains(payee)) && !payee.isEmpty { score += 3 }
            if !hint.name.isEmpty && (t.narration.contains(hint.name) || payee.contains(hint.name)) { score += 1 }
            if !hint.account.isEmpty && p.account == hint.account { score += 2 }
            if hint.amount > 0 && abs(abs(u) - hint.amount) <= hint.amount * 0.3 { score += 1 }
            let item = Item(t: t, amount: u, currency: c, account: p.account, score: score,
                            owner: t.links.lazy.compactMap { owners[$0] }.first)
            if !query.isEmpty {
                if !matches(item, query) { continue }
            } else if onlyRelated && score < 2 && !picked.contains(t.id) {
                continue
            }
            out.append(item)
        }
        switch sort {
        case .related: out.sort { $0.score != $1.score ? $0.score > $1.score : $0.t.date > $1.t.date }
        case .date: out.sort { $0.t.date > $1.t.date }
        case .amount: out.sort { abs($0.amount) > abs($1.amount) }
        case .payee, .narration: break
        }
        return out
    }

    /// every word must match: ">20" / "<30" amounts, a number, a date prefix, or text
    private func matches(_ i: Item, _ query: String) -> Bool {
        for w in query.split(separator: " ").map(String.init) {
            if (w.hasPrefix(">") || w.hasPrefix("<")), let n = Double(w.dropFirst()) {
                if w.hasPrefix(">") ? abs(i.amount) <= n : abs(i.amount) >= n { return false }
                continue
            }
            if let n = Double(w), !w.contains("-") {
                if abs(abs(i.amount) - n) < 0.005 { continue }
            }
            if w.range(of: #"^\d{4}(-\d{1,2}){0,2}$"#, options: .regularExpression) != nil {
                if i.t.date.hasPrefix(w) { continue } else { return false }
            }
            let hay = [i.t.payee, i.t.narration, i.account, acctDisplay(i.account)].joined(separator: " ").lowercased()
            if hay.contains(w) || fuzzy(w, i.payee) > 0 { continue }
            return false
        }
        return true
    }
}

/// from a transaction: choose the subscription to link it to, or start a new one
struct SubPickSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let t: Entry
    let onNew: () -> Void
    @State private var q = ""

    var body: some View {
        NavigationStack {
            List {
                Button { dismiss(); onNew() } label: { Label(LS("新建订阅"), systemImage: "plus.circle") }
                Section(LS("关联到已有订阅")) {
                    ForEach(list) { s in
                        Button { Task { await link(s) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name)
                                    Text(s.period.name + " · " + money(s.amount, s.currency) + (s.status == .active ? "" : " · " + s.status.name))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if s.account == expenseAccount { Text(LS("同科目")).font(.caption2).foregroundStyle(Color.jade) }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .searchable(text: $q, prompt: LS("搜索订阅"))
            .navigationTitle(LS("加入订阅管理"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(LS("取消")) { dismiss() } } }
        }
    }

    private var expenseAccount: String? { t.postings.first { $0.account.hasPrefix("Expenses:") }?.account }

    private var list: [Subscription] {
        let all = store.subs
        let k = q.trimmed.lowercased()
        let f = k.isEmpty ? all : all.filter { $0.name.lowercased().contains(k) || $0.payee.lowercased().contains(k) || fuzzy(k, $0.name) > 0 }
        // same account and payee first
        return f.sorted { a, b in
            let sa = (a.account == expenseAccount ? 2 : 0) + (a.payee == t.payee ? 1 : 0)
            let sb = (b.account == expenseAccount ? 2 : 0) + (b.payee == t.payee ? 1 : 0)
            return sa != sb ? sa > sb : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func link(_ s: Subscription) async {
        let ops = await store.linkOps([t], link: s.link, label: LS("关联订阅：%@ %@ 笔", s.name, 1))
        guard !ops.isEmpty else { dismiss(); return }
        await store.commit(ops, word: LS("已关联到 %@", s.name), closing: { dismiss() })
    }
}

/// the next two months of charges, day by day
struct SubscriptionCalendarView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let today = Day.today()
        let end = Day.shift(today, 62)
        var byDate: [String: [(Subscription, String)]] = [:]
        for s in store.subs where s.status == .active {
            var d = s.nextCharge(onOrAfter: today), n = 0
            while d <= end && n < 70 {
                if s.trialEnd.map({ d > $0 }) ?? true { byDate[d, default: []].append((s, d)) }
                d = s.nextCharge(onOrAfter: Day.shift(d, 1)); n += 1
            }
        }
        let months = Dictionary(grouping: byDate.keys.sorted(), by: { Day.ym($0) }).sorted { $0.key < $1.key }
        return List {
            if byDate.isEmpty { Text(LS("近两个月没有扣费")).foregroundStyle(.secondary) }
            ForEach(months, id: \.key) { m in
                let total = monthTotal(m.value.flatMap { byDate[$0] ?? [] }.map { $0.0 })
                Section {
                    ForEach(m.value, id: \.self) { d in
                        ForEach(Array((byDate[d] ?? []).enumerated()), id: \.offset) { _, pair in
                            NavigationLink { SubscriptionDetailView(name: pair.0.name) } label: {
                                HStack(spacing: 12) {
                                    VStack(spacing: 0) {
                                        Text(String(d.suffix(2))).font(.headline.monospacedDigit())
                                        Text(daysText(d, today: today)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(width: 52)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pair.0.name)
                                        Text((pair.0.manual ? LS("手动续费") : LS("自动扣费")) + " · " + acctLabel(pair.0.paymentAccount))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(money(pair.0.amount, pair.0.currency)).monospacedDigit().sensitive()
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(Day.monthLabel(m.key))
                        Spacer()
                        Text(money(total, store.L?.base ?? "CNY", 0)).monospacedDigit().sensitive()
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle(LS("订阅日历"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func monthTotal(_ subs: [Subscription]) -> Double {
        guard let L = store.L else { return 0 }
        return subs.reduce(0.0) { $0 + (toCNY(L, $1.amount, $1.currency) ?? 0) }
    }
}
extension Entry: Identifiable {}
