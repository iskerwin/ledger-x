import SwiftUI
import LedgerKit

/// the window's time, in the toolbar for every page that looks at a stretch of it: the arrows step by the unit, the
/// title opens the units, a day or a span of days on the calendar and the way back to the current one
struct PeriodBar: View {
    @Binding var period: ViewPeriod
    @State private var choosingDay = false
    @State private var choosingDays = false
    @State private var from = Day.shift(Day.today(), -29)
    @State private var to = Day.today()

    var body: some View {
        HStack(spacing: 2) {
            Button("上一期", systemImage: "chevron.left") { period = period.stepped(-1) }
                .disabled(!period.steps)
            Menu {
                Picker(selection: Binding(get: { period.unit }, set: { period = period.showing($0) })) {
                    Text("按月").tag(ViewPeriod.Unit.month)
                    Text("按季度").tag(ViewPeriod.Unit.quarter)
                    Text("按年").tag(ViewPeriod.Unit.year)
                    Text("近 30 天").tag(ViewPeriod.Unit.recent)
                    Text("全部时间").tag(ViewPeriod.Unit.all)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                Divider()
                Button("选择日期…") { choosingDay = true }
                Button("选择时间段…") {
                    if let span = period.span { (from, to) = (span.0, min(span.1, Day.today())) }
                    choosingDays = true
                }
                Button("回到本期") { period = ViewPeriod(unit: period.unit) }
                    .disabled(period.isCurrent && period.day == nil && period.days == nil)
            } label: {
                // as wide as the longest title, so the arrows stay put
                Text(period.title).monospacedDigit().frame(minWidth: 112)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            Button("下一期", systemImage: "chevron.right") { period = period.stepped(1) }
                .disabled(!period.steps || period.isCurrent)
        }
        .labelStyle(.iconOnly)
        .popover(isPresented: $choosingDay) {
            DayPicker(title: "日期", day: Binding(get: { period.day ?? Day.today() }, set: {
                period.days = nil
                period.day = $0
                choosingDay = false
            }), latest: Date())
            .padding(12)
        }
        .popover(isPresented: $choosingDays) {
            VStack(alignment: .trailing, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    DayPicker(title: "开始", day: $from, latest: Date())
                    DayPicker(title: "结束", day: $to, latest: Date())
                }
                Button("确定") {
                    period.days = ViewPeriod.Days(from: from, to: to)
                    choosingDays = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }
}

/// the account the journal keeps to, with what's under it; every account the ledger names and each one above them
struct AccountFilter: View {
    let ledger: Ledger
    @Binding var account: String?

    var body: some View {
        Menu {
            Button("全部账户") { account = nil }
            ForEach(["Assets", "Liabilities", "Income", "Expenses", "Equity"], id: \.self) { root in
                let names = accounts.filter { $0.hasPrefix(root + ":") }
                if !names.isEmpty {
                    Section(ZH[root] ?? root) {
                        ForEach(names, id: \.self) { name in
                            Button(String(repeating: "    ", count: name.split(separator: ":").count - 2) + accountTitle(ledger, name)) { account = name }
                        }
                    }
                }
            }
        } label: {
            Label(account.map { accountTitle(ledger, $0) } ?? "全部账户", systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
    }

    /// in the tree's order, each parent before what's under it
    private var accounts: [String] {
        ledger.memoized("mac|filterAccounts") {
            var names = Set<String>()
            for name in ledger.accounts.keys {
                let parts = name.split(separator: ":")
                for depth in 2...max(2, parts.count) where depth <= parts.count { names.insert(parts.prefix(depth).joined(separator: ":")) }
            }
            return names.sorted()
        }
    }
}

private struct FilterTagKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    /// puts a tag into the window's search, as clicking one does on Fava; nil where there is no search to put it in
    var filterTag: ((String) -> Void)? {
        get { self[FilterTagKey.self] }
        set { self[FilterTagKey.self] = newValue }
    }
}

extension View {
    /// the window's search on a page that adds up only what it finds
    func filtering(_ text: Binding<String>, _ searching: Binding<Bool>) -> some View {
        searchable(text: text, isPresented: searching, placement: .toolbar, prompt: Text("标签、收付款方或文字"))
    }
}

/// `filter` with `#tag` added, unless it's there already
func addingTag(_ tag: String, to filter: String) -> String {
    let token = "#" + tag
    let words = filter.split(separator: " ").map(String.init)
    return words.contains(token) ? filter : (words + [token]).joined(separator: " ")
}
