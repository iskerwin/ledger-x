import SwiftUI
import LedgerKit

/// the panels both the card and the full form open over themselves
enum EntryPanel: String, Identifiable {
    case rate, pay, marks
    var id: String { rawValue }
}

/// 记一笔: the phone's quick card first; 完整表单 (表单, 分录, 文本) one step in; in its own window (`EntryWindow`)
struct NewEntrySheet: View {
    let ledger: Ledger
    let folder: URL
    private let config: LedgerXConfig?
    private let derived: Derived
    private let subscriptionLinks: Set<String>
    private let editing: Bool
    /// closes the window: saved, given up or kept as a draft
    private let done: () -> Void
    @State private var draft: Draft
    /// what counts as nothing changed: closing from it needs no asking
    @State private var baseline: Draft
    /// each kind as it was left, to come back to
    @State private var snapshots: [DraftKind: Draft] = [:]
    /// the kind 表单 goes back to from 分录 or 文本
    @State private var formKind: DraftKind
    /// a new form for each new entry, so the cursor starts in the amount again
    @State private var entry = 0
    @State private var panel: EntryPanel?
    @State private var message = ""
    @State private var saving = false
    @State private var review: FolderSave?
    @State private var another = false
    @State private var leaving = false
    /// 完整表单 open over the card
    @State private var full: Bool
    /// the card's category grid in the order it had as this opened: saving one doesn't move the cells
    @State private var gridOrder: [String: [String]]

    private static let formKinds: [DraftKind] = [.expense, .income, .transfer]

    private enum Mode: Hashable { case form, multi, raw }

    init(ledger: Ledger, config: LedgerXConfig?, folder: URL, editing: Draft? = nil, done: @escaping () -> Void) {
        self.ledger = ledger
        self.folder = folder
        self.config = config
        self.editing = editing != nil
        self.done = done
        let derived = folderDerived(ledger, config: config)
        self.derived = derived
        subscriptionLinks = Set(subscriptions(ledger).map(\.link))
        let blank = Self.blank(.expense, ledger: ledger, derived: derived, config: config)
        let opened = editing ?? KeptDraft.read(folder) ?? blank
        _draft = State(initialValue: opened)
        _baseline = State(initialValue: editing ?? blank)
        _formKind = State(initialValue: Self.formKinds.contains(opened.kind) ? opened.kind : .expense)
        _full = State(initialValue: !Self.fitsCard(opened))
        _gridOrder = State(initialValue: Dictionary(uniqueKeysWithValues: ["Expenses:", "Income:"].map { ($0, categoryGroups(derived, root: $0).map(\.id)) }))
    }

    /// what the card can show: spending, income or a transfer, not shared out (AA)
    private static func fitsCard(_ draft: Draft) -> Bool { formKinds.contains(draft.kind) && !draft.split }

    private static func blank(_ kind: DraftKind, ledger: Ledger, derived: Derived, config: LedgerXConfig?) -> Draft {
        var draft = newDraft(kind, derived, defaultFunding: config?.defaultFunding)
        draft.currency = derived.acctCcy[draft.funding] ?? ledger.base
        draft.events = activeEvents(ledger, on: draft.date).map(\.tag)
        return draft
    }

    var body: some View {
        Group {
            if !full && Self.fitsCard(draft) {
                QuickCard(draft: $draft, ledger: ledger, derived: derived, subscriptionLinks: subscriptionLinks, gridOrder: gridOrder,
                          editing: editing, saving: saving, message: message, blank: { Self.blank($0, ledger: ledger, derived: derived, config: config) }, setKind: setKind,
                          openFull: { message = ""; full = true }, close: close, save: save(another:)) { panel = $0 }
                    .id(entry)
                    .frame(width: 400, height: EntryWindow.fitted(740))
            } else {
                form
            }
        }
        .sheet(item: $panel) { panel in
            switch panel {
            case .rate: RateSheet(draft: $draft, ledger: ledger, derived: derived)
            case .pay: PaySheet(draft: $draft, ledger: ledger, derived: derived)
            case .marks: MarkSheet(draft: $draft, ledger: ledger)
            }
        }
        // new entries follow the events of their day until picked by hand
        .onChange(of: draft.date) {
            if !draft.eventsTouched && draft.kind != .transfer && draft.kind != .raw {
                draft.events = activeEvents(ledger, on: draft.date).map(\.tag)
            }
        }
        .alert(review?.issues.first?.title ?? "", isPresented: reviewing) {
            if review?.issues.contains(where: \.blocking) == false {
                Button("仍然保存") { if let review { write(review) } }
            }
            Button("返回修改", role: .cancel) {}
        } message: {
            Text(review?.issues.map(\.detail).joined(separator: "\n") ?? "")
        }
        .confirmationDialog("这笔还没有保存", isPresented: $leaving) {
            Button("继续编辑", role: .cancel) {}
            if !editing {
                Button("保留草稿") {
                    KeptDraft.write(draft, folder)
                    done()
                }
            }
            Button("放弃", role: .destructive) {
                if !editing { KeptDraft.clear(folder) }
                done()
            }
        }
    }

    private var form: some View {
        VStack(spacing: 0) {
            header
            EntryForm(draft: $draft, ledger: ledger, derived: derived, subscriptionLinks: subscriptionLinks) { panel = $0 }
                .id(entry)
            Text(message)
                .font(.callout)
                .foregroundStyle(Color.loss)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.horizontal, 20)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                if !editing {
                    Button("保存再记") { save(another: true) }
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                        .disabled(saving)
                }
                Button("保存") { save(another: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 620, height: EntryWindow.fitted(640))
    }

    /// back to the card, the kinds on the left, how it is written on the right; a refund stays one
    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Text(editing ? "编辑交易" : "记一笔").font(.headline)
                if draft.kind != .refund && !draft.split {
                    Button("返回", systemImage: "chevron.left", action: back)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("返回")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if draft.kind == .refund {
                Text(draft.kind.label).foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker(selection: Binding(get: { draft.kind }, set: { setKind($0) })) {
                        ForEach(Self.formKinds) { Text($0.label).tag($0) }
                    } label: {
                        EmptyView()
                    }
                    .frame(width: 220)
                    Spacer()
                    Picker(selection: Binding(get: { mode }, set: { setMode($0) })) {
                        Text("表单").tag(Mode.form)
                        Text(DraftKind.multi.label).tag(Mode.multi)
                        Text(DraftKind.raw.label).tag(Mode.raw)
                    } label: {
                        EmptyView()
                    }
                    .frame(width: 200)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var mode: Mode { draft.kind == .multi ? .multi : draft.kind == .raw ? .raw : .form }

    /// the card again: 分录 and 文本 go back as the kind they read as, or stay and say why
    private func back() {
        if mode != .form && !setMode(.form) { return }
        message = ""
        full = false
    }

    @discardableResult
    private func setMode(_ mode: Mode) -> Bool {
        switch mode {
        case .multi: return setKind(.multi)
        case .raw: return setKind(.raw)
        case .form:
            // a whole entry goes back as the kind it reads as; one the form can't hold stays, and says why
            let checked = validateText(draftText(draft, ledger, derived), ledger, single: true)
            let shown = checked.ok ? checked.txn.flatMap { editDraft($0, ledger, derived)?.kind }.flatMap { Self.formKinds.contains($0) ? $0 : nil } : nil
            return setKind(shown ?? formKind)
        }
    }

    /// content moves between the kinds only when none of it is lost; otherwise this stays as it is and says why
    @discardableResult
    private func setKind(_ kind: DraftKind) -> Bool {
        guard kind != draft.kind else { return true }
        message = ""
        let next: Draft
        if [.multi, .raw].contains(kind) || [.multi, .raw].contains(draft.kind) {
            switch convertingEditor(draft, to: kind, ledger: ledger, derived: derived, previous: snapshots[kind]) {
            case .success(let converted): next = converted
            case .failure(let error):
                message = error.message
                return false
            }
            snapshots[draft.kind] = draft
        } else {
            let switched = switchingKind(draft, to: kind, remembering: snapshots, fundingCurrency: derived.acctCcy[draft.funding], defaultCurrency: nil)
            snapshots = switched.snapshots
            next = switched.draft
        }
        if Self.formKinds.contains(kind) { formKind = kind }
        draft = next
        return true
    }

    private func close() {
        if draft == baseline {
            if !editing { KeptDraft.clear(folder) }
            done()
        } else {
            leaving = true
        }
    }

    private var reviewing: Binding<Bool> {
        Binding(get: { review != nil }, set: { if !$0 { review = nil } })
    }

    private func save(another: Bool) {
        saving = true
        message = ""
        self.another = another
        let draft = draft, folder = folder
        Task { @MainActor in
            let result = await Task.detached { prepareFolderSave(draft, folder: folder) }.value
            saving = false
            switch result {
            case .failure(let error): message = error.message
            case .success(let prepared):
                if prepared.issues.isEmpty { write(prepared) } else { review = prepared }
            }
        }
    }

    private func write(_ prepared: FolderSave) {
        do {
            try commitFolderSave(prepared, folder: folder)
            if !editing { KeptDraft.clear(folder) }
            if another { startNext() } else { done() }
        } catch {
            message = error.localizedDescription
        }
    }

    /// the next entry of the same kind, on the same day from the same account
    private func startNext() {
        let kind = Self.formKinds.contains(draft.kind) ? draft.kind : formKind
        var next = Self.blank(kind, ledger: ledger, derived: derived, config: config)
        next.date = draft.date
        if !draft.funding.isEmpty {
            next.funding = draft.funding
            next.currency = derived.acctCcy[draft.funding] ?? next.currency
        }
        draft = next
        baseline = next
        snapshots = [:]
        message = ""
        entry += 1
    }
}

/// a new entry left unfinished, for this ledger alone
private enum KeptDraft {
    private static func key(_ folder: URL) -> String { "draft:" + folder.path }

    static func read(_ folder: URL) -> Draft? {
        UserDefaults.standard.data(forKey: key(folder)).flatMap { try? JSONDecoder().decode(Draft.self, from: $0) }
    }

    static func write(_ draft: Draft, _ folder: URL) {
        UserDefaults.standard.set(try? JSONEncoder().encode(draft), forKey: key(folder))
    }

    static func clear(_ folder: URL) {
        UserDefaults.standard.removeObject(forKey: key(folder))
    }
}
