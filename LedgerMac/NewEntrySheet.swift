import SwiftUI
import LedgerKit

/// the panels both the card and the full form open over themselves
enum EntryPanel: String, Identifiable {
    case rate, pay, marks
    var id: String { rawValue }
}

/// 记一笔, as on the phone: the card, or the full form for what it can't show (分录, 文本, 退款, AA)
struct NewEntrySheet: View {
    let ledger: Ledger
    let folder: URL
    private let derived: Derived
    private let frequent: [Template]
    private let subscriptionLinks: Set<String>
    private let initial: Draft
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Draft
    /// each kind as it was left, to come back to
    @State private var snapshots: [DraftKind: Draft] = [:]
    @State private var full: Bool
    @State private var panel: EntryPanel?
    @State private var message = ""
    @State private var saving = false
    @State private var review: FolderSave?

    private static let cardKinds: [DraftKind] = [.expense, .income, .transfer]

    init(ledger: Ledger, config: LedgerXConfig?, folder: URL, editing: Draft? = nil) {
        self.ledger = ledger
        self.folder = folder
        let derived = folderDerived(ledger, config: config)
        self.derived = derived
        frequent = templates(ledger, pinned: [], hidden: [])
        subscriptionLinks = Set(subscriptions(ledger).map(\.link))
        var draft = editing ?? newDraft(.expense, derived, defaultFunding: config?.defaultFunding)
        if editing == nil {
            draft.currency = derived.acctCcy[draft.funding] ?? ledger.base
            draft.events = activeEvents(ledger, on: draft.date).map(\.tag)
        }
        initial = draft
        _draft = State(initialValue: draft)
        _full = State(initialValue: Self.needsFullForm(draft))
    }

    private static func needsFullForm(_ draft: Draft) -> Bool {
        [.refund, .multi, .raw].contains(draft.kind) || draft.split
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if full {
                EntryForm(draft: $draft, ledger: ledger, derived: derived, subscriptionLinks: subscriptionLinks) { panel = $0 }
            } else {
                EntryCard(draft: $draft, ledger: ledger, derived: derived, frequent: frequent, subscriptionLinks: subscriptionLinks,
                          openFull: { full = true }, open: { panel = $0 })
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(Color.loss)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.horizontal, 20)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 560, height: 600)
        // the card has its own cards on the page; a form brings its own colours, and on the page its rows all but vanish in dark mode
        .background(full ? Color.clear : Color.page)
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
    }

    /// the kind in the middle whichever page this is; the way back on its left, the other pages on its right
    private var header: some View {
        ZStack {
            if draft.kind == .refund {
                Text(draft.kind.label).font(.headline)
            } else {
                let kinds = full ? DraftKind.allCases.filter { $0 != .refund } : Self.cardKinds
                Picker(selection: Binding(get: { draft.kind }, set: { setKind($0) })) {
                    ForEach(kinds) { Text($0.label).tag($0) }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: full ? 340 : 220)
            }
            HStack {
                // what opened here has no card to go back to: it would come up empty
                if full && !Self.needsFullForm(initial) && draft.kind != .refund && (!draft.split || [.multi, .raw].contains(draft.kind)) {
                    Button("记一笔", systemImage: "chevron.left") { backToCard() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.jade)
                }
                Spacer()
                if !full {
                    Menu {
                        Button("完整表单", systemImage: "list.bullet.rectangle") { full = true }
                        Button("分录（多行）", systemImage: "list.number") { if setKind(.multi) { full = true } }
                        Button("文本（Beancount 指令）", systemImage: "text.alignleft") { if setKind(.raw) { full = true } }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("更多")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// as the phone: content moves between the kinds it fits, and what 分录 or 文本 can't hand over waits there for the way back
    @discardableResult
    private func setKind(_ kind: DraftKind) -> Bool {
        guard kind != draft.kind else { return true }
        message = ""
        let next: Draft
        if [.multi, .raw].contains(kind) || [.multi, .raw].contains(draft.kind) {
            let leaving = [.multi, .raw].contains(draft.kind)
            let previous = snapshots[kind] ?? (initial.kind == kind ? initial : nil)
            if let back = returningToSetAside(draft, to: kind) {
                next = back
            } else {
                switch convertingEditor(draft, to: kind, ledger: ledger, derived: derived, previous: previous) {
                case .success(let converted):
                    next = converted
                case .failure(.incomplete) where leaving:
                    next = settingAside(draft, to: kind, previous: previous)
                    message = "「\(draft.kind.label)」里还没填完的内容已保留，切回「\(draft.kind.label)」可以继续"
                case .failure(.notRepresentable) where leaving:
                    next = settingAside(draft, to: kind, previous: previous)
                    message = "「\(kind.label)」显示不了「\(draft.kind.label)」的内容，已原样保留，切回「\(draft.kind.label)」可以继续"
                case .failure(let error):
                    message = error.message
                    return false
                }
            }
            snapshots[draft.kind] = draft
        } else {
            let switched = switchingKind(draft, to: kind, remembering: snapshots, fundingCurrency: derived.acctCcy[draft.funding], defaultCurrency: nil)
            snapshots = switched.snapshots
            next = switched.draft
        }
        draft = next
        return true
    }

    /// a whole entry the card can show goes back as its kind; anything else to the kind this opened as, set aside for the way back
    private func backToCard() {
        if [.multi, .raw].contains(draft.kind) {
            let checked = validateText(draftText(draft, ledger, derived), ledger, single: true)
            let shown = checked.ok ? checked.txn.flatMap { editDraft($0, ledger, derived)?.kind }.flatMap { Self.cardKinds.contains($0) ? $0 : nil } : nil
            guard setKind(shown ?? initial.kind) else { return }
        }
        full = Self.needsFullForm(draft)
    }

    private var reviewing: Binding<Bool> {
        Binding(get: { review != nil }, set: { if !$0 { review = nil } })
    }

    private func save() {
        saving = true
        message = ""
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
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
