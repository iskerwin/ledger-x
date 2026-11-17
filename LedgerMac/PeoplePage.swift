import SwiftUI
import LedgerKit

/// 个人往来, as the phone's 账户 › 往来 lists people: who owes whom, each one's entries, and a lend, collect, borrow or
/// repay written from here. The personal receivable carries `person:`; a loan account is the person you borrowed from.
struct PeoplePage: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    @State private var picked: String?
    @State private var showSettled = false
    @State private var adding: LoanRequest?

    var body: some View {
        let all = people(ledger)
        let open = all.filter { !$0.settled }, settled = all.filter(\.settled)
        let name = picked ?? open.first?.name ?? settled.first?.name
        Group {
            if all.isEmpty {
                ContentUnavailableView {
                    Label(LS("没有个人往来"), systemImage: "person.2")
                } actions: {
                    Button(LS("登记往来…")) { adding = LoanRequest(name: nil) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.page)
            } else {
                SplitPage {
                    ForEach(open) { row($0, picked: name == $0.name) }
                    if !settled.isEmpty {
                        Button { showSettled.toggle() } label: {
                            Label(LS("已结清 %@ 人", settled.count), systemImage: showSettled ? "chevron.down" : "chevron.right")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.top, 10)
                        if showSettled { ForEach(settled) { row($0, picked: name == $0.name) } }
                    }
                } detail: {
                    if let person = all.first(where: { $0.name == name }) {
                        PersonDetail(ledger: ledger, config: config, folder: folder, person: person) { adding = LoanRequest(name: person.name) }
                            .id(person.name)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button(LS("登记往来…"), systemImage: "plus") { adding = LoanRequest(name: name) }
            }
        }
        .sheet(item: $adding) { LoanSheet(request: $0, ledger: ledger, config: config, folder: folder) }
    }

    private func row(_ person: Person, picked: Bool) -> some View {
        let net = person.netCNY
        return PickRow(title: personName(person.name), caption: personState(person),
                       trailing: person.settled ? "" : money(abs(net), ledger.base),
                       tint: person.settled ? .primary : net > 0 ? Color.gain : Color.loss,
                       picked: picked) { self.picked = person.name }
    }
}

func personName(_ name: String) -> String { name.isEmpty ? LS("未注明对方") : name }

func personState(_ person: Person) -> String {
    let state = person.settled ? LS("已结清") : person.netCNY > 0 ? LS("他欠我") : LS("我欠他")
    return state + (person.last.map { " · " + LS("最近 %@", $0) } ?? "")
}

/// one person: what is owed each way in each currency, and every entry with them
private struct PersonDetail: View {
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    let person: Person
    let add: () -> Void
    @State private var lines: [JournalRow] = []
    @State private var widths = EntryWidths()
    @State private var generation = 0
    @State private var selected = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\JournalRow.date, order: .reverse)]
    @State private var tasks = EntryTasks()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Card(summary: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(personName(person.name)).font(.title3.weight(.semibold))
                        if person.settled {
                            Label(LS("已结清"), systemImage: "checkmark.seal").foregroundStyle(Color.gain)
                        } else {
                            ForEach(person.net.filter { abs($0.value) >= 0.005 }.sorted { $0.key < $1.key }, id: \.key) { owed in
                                LabeledContent(owed.value > 0 ? LS("他欠我") : LS("我欠他")) {
                                    Text(money(abs(owed.value), owed.key)).monospacedDigit().foregroundStyle(owed.value > 0 ? Color.gain : Color.loss)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            Divider()
            EntryList(lines: lines, generation: generation, balances: [:], widths: widths, ledger: ledger, config: config, folder: folder,
                      sortOrder: $sortOrder, selected: $selected, tasks: $tasks, focus: false)
        }
        .background(Color.page)
        .task(id: "\(ObjectIdentifier(ledger))|\(person.name)|\(sortOrder)") { await rebuild() }
        .entryTasks($tasks, ledger: ledger, config: config, folder: folder)
    }

    private func rebuild() async {
        let ledger = ledger, name = person.name, sortOrder = sortOrder
        let next = await Task.detached { () -> ([JournalRow], EntryWidths) in
            let theirs = Set(personEntries(ledger, name).map(ObjectIdentifier.init))
            let lines = journalRows(ledger).filter { theirs.contains(ObjectIdentifier($0.entry)) }.sorted(using: sortOrder)
            return (lines, EntryWidths.measure(lines, balances: [:]))
        }.value
        guard !Task.isCancelled else { return }
        lines = next.0
        widths = next.1
        generation += 1
        let shown = Set(lines.map(\.id))
        if !selected.isSubset(of: shown) { selected.formIntersection(shown) }
    }
}

struct LoanRequest: Identifiable {
    let id = UUID()
    /// the person it's with; nil for someone new
    let name: String?
}

/// 登记往来: lend, collect, borrow or repay; the amount left empty is what is outstanding
private struct LoanSheet: View {
    let request: LoanRequest
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    private let derived: Derived
    @State private var d = LoanDraft()
    @State private var busy = false
    @State private var message = ""
    @State private var review: FolderSave?
    @Environment(\.dismiss) private var dismiss

    init(request: LoanRequest, ledger: Ledger, config: LedgerXConfig?, folder: URL) {
        self.request = request
        self.ledger = ledger
        self.config = config
        self.folder = folder
        derived = folderDerived(ledger, config: config)
    }

    var body: some View {
        let person = people(ledger).first { $0.name == d.name.trimmed }
        let owed = loanOutstanding(d, ledger)
        let needsKey = !d.kind.receivable && person?.loan(ledger) == nil
        VStack(alignment: .leading, spacing: 16) {
            Text(LS("登记往来")).font(.headline)
            Form {
                Picker(LS("类型"), selection: $d.kind) {
                    ForEach(LoanKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if request.name == nil {
                    TextField(LS("对方"), text: $d.name, prompt: Text(LS("称呼（如 五姨、王五）")))
                } else {
                    LabeledContent(LS("对方"), value: personName(d.name))
                }
                if needsKey {
                    TextField(LS("借款账户名"), text: $d.key, prompt: Text("WangWu"))
                }
                DateRow(title: LS("日期"), day: $d.date, latest: Date())
                LabeledContent(LS("金额")) {
                    HStack {
                        TextField(LS("金额"), text: $d.amount, prompt: Text(owed.map { fmtNum($0) } ?? "0.00"))
                            .multilineTextAlignment(.trailing).monospacedDigit().labelsHidden()
                        Picker(LS("币种"), selection: $d.currency) {
                            ForEach(currencies, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                AccountField(title: d.kind.incoming ? LS("收款账户") : LS("付款账户"), prefixes: ["Assets:", "Liabilities:CreditCard"],
                             derived: derived, account: $d.account, excluding: "Assets:Receivable")
                TextField(LS("备注"), text: $d.note, prompt: Text(d.kind.label))
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(LS("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(LS("保存")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || d.name.trimmed.isEmpty || d.account.isEmpty || (d.amount.trimmed.isEmpty && owed == nil)
                              || (needsKey && !validAccountPart(d.key.trimmed)))
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: start)
        .alert(message, isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) {}
        .folderReview(writer, $review, step: LS("登记往来")) { dismiss() }
    }

    private var writer: FolderWriter {
        FolderWriter(folder: folder, busy: $busy, message: $message, review: $review)
    }

    /// what they last used with this person, or the ledger's own
    private var currencies: [String] {
        var list = people(ledger).first { $0.name == d.name.trimmed }.map { Array($0.net.keys).sorted() } ?? []
        for c in [ledger.base] + derived.currencies where !list.contains(c) { list.append(c) }
        if !list.contains(d.currency) { list.append(d.currency) }
        return list
    }

    /// someone who owes: collecting; someone owed: repaying; in the currency it's in
    private func start() {
        d.currency = ledger.base
        d.account = derived.rankAccounts(["Assets:", "Liabilities:CreditCard"]).first { !$0.hasPrefix("Assets:Receivable") } ?? ""
        guard let name = request.name, let person = people(ledger).first(where: { $0.name == name }) else { return }
        d.name = name
        if let owed = person.net.filter({ abs($0.value) >= 0.005 }).sorted(by: { $0.key < $1.key }).first {
            d.currency = owed.key
            d.kind = owed.value > 0 ? .collect : .repay
        }
    }

    private func save() {
        let d = d
        writer.prepare(d, step: LS("登记往来")) { dismiss() }
    }
}
