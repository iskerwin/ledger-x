import SwiftUI
import LedgerKit

/// a subscription change worked out off the main thread, then written with 编辑 › 撤销 to take it back; what it would
/// break is asked about first, and a refusal stays on screen with the form as it was
@MainActor
struct SubscriptionWriter {
    let folder: URL
    @Binding var busy: Bool
    @Binding var message: String
    @Binding var review: FolderSave?

    func prepare(_ change: SubscriptionChange, step: String, done: @escaping @MainActor () -> Void = {}) {
        guard !busy else { return }
        busy = true
        message = ""
        let folder = folder
        Task { @MainActor in
            let result = await Task.detached { prepareFolderSubscription(change, folder: folder) }.value
            busy = false
            switch result {
            case .failure(let error): message = error.message
            case .success(let save): if save.issues.isEmpty { write(save, step: step, done: done) } else { review = save }
            }
        }
    }

    func write(_ save: FolderSave, step: String, done: @MainActor () -> Void) {
        do {
            try SaveUndo.commit(save, folder: folder, name: step)
            done()
        } catch {
            message = error.localizedDescription
        }
    }
}

extension View {
    /// what a subscription save would break, asked before it is written anyway
    func subscriptionReview(_ writer: SubscriptionWriter, _ review: Binding<FolderSave?>, step: String, done: @escaping @MainActor () -> Void) -> some View {
        alert(review.wrappedValue?.issues.first?.title ?? "", isPresented: review.present()) {
            if review.wrappedValue?.issues.contains(where: \.blocking) == false {
                Button(LS("仍然保存")) { if let save = review.wrappedValue { writer.write(save, step: step, done: done) } }
            }
            Button(LS("返回修改"), role: .cancel) {}
        } message: {
            Text(review.wrappedValue?.issues.map { $0.title + "\n" + $0.detail }.joined(separator: "\n\n") ?? "")
        }
    }
}

/// 记一笔 for a subscription, as the phone fills it: payee, category, paying account, amount and its ^sub- link, dated today
func subscriptionChargeDraft(_ s: Subscription, _ ledger: Ledger, _ config: LedgerXConfig?) -> Draft? {
    guard !s.account.isEmpty, !s.paymentAccount.isEmpty else { return nil }
    var d = newDraft(.expense, folderDerived(ledger, config: config), defaultFunding: config?.defaultFunding)
    d.date = Day.today()
    d.payee = s.payee.isEmpty ? s.name : s.payee
    d.narration = s.payee.isEmpty || s.payee == s.name ? "" : s.name
    d.account = s.account
    d.funding = s.paymentAccount
    d.amount = jsNumberString(roundTo(s.amount, 2))
    d.currency = s.currency
    d.link = s.link
    d.events = activeEvents(ledger, on: d.date).map(\.tag)
    return d
}

/// 添加订阅, 调价或更改, 恢复订阅, 调整到期日 and 修正记录: the phone's form, in a sheet
struct SubscriptionEditor: View {
    let ledger: Ledger
    let folder: URL
    private let derived: Derived
    private let baseline: SubDraft
    @State private var draft: SubDraft
    @State private var busy = false
    @State private var message = ""
    @State private var review: FolderSave?
    @State private var leaving = false
    @Environment(\.dismiss) private var dismiss

    init(draft: SubDraft, ledger: Ledger, config: LedgerXConfig?, folder: URL) {
        self.ledger = ledger
        self.folder = folder
        derived = folderDerived(ledger, config: config)
        baseline = draft
        _draft = State(initialValue: draft)
    }

    private var writer: SubscriptionWriter { SubscriptionWriter(folder: folder, busy: $busy, message: $message, review: $review) }

    private var title: String {
        draft.dueOnly ? LS("调整到期日") : draft.mode == .new ? LS("添加订阅") : draft.mode == .correct ? LS("修正记录")
            : draft.original?.status != .active ? LS("恢复订阅") : LS("调价或更改")
    }

    /// the next charge as it is now
    private var current: String? { draft.original.map { $0.nextCharge(onOrAfter: Day.today()) } }

    private var nameTaken: Bool { draft.nameTaken(subscriptions(ledger)) }

    private var dirty: Bool { state(draft) != state(baseline) }

    private func state(_ d: SubDraft) -> [String] {
        [d.name, d.amount, d.currency, String(describing: d.period), d.start, d.date, d.account, d.funding, d.payee, String(d.extended), d.next,
         String(d.trial), d.trialEnd, d.link, String(d.manual), String(d.variable)]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(LS("取消")) { if dirty { leaving = true } else { dismiss() } }
                    .keyboardShortcut(.cancelAction).disabled(busy)
                Button(LS("保存"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || draft.sub == nil || nameTaken || (draft.dueOnly && (draft.next <= draft.date || draft.next == current)))
            }
            .padding(16)
            Form {
                if draft.dueOnly { dueSection } else { fields }
                if let text = draft.text {
                    DisclosureGroup(LS("将写入")) {
                        Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(busy)
            Text(nameTaken ? LS("已有同名订阅，请换一个名称") : message)
                .font(.callout).foregroundStyle(Color.loss).lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).padding(.horizontal, 16)
        }
        .frame(width: 560, height: draft.dueOnly ? 300 : 640)
        .interactiveDismissDisabled(busy || dirty)
        .confirmationDialog(LS("还有未保存的修改"), isPresented: $leaving, titleVisibility: .visible) {
            Button(LS("继续编辑"), role: .cancel) {}
            Button(LS("放弃修改"), role: .destructive) { dismiss() }
        }
        .subscriptionReview(writer, $review, step: step) { dismiss() }
    }

    private var step: String { draft.mode == .new ? LS("添加订阅") : title }

    @ViewBuilder private var dueSection: some View {
        Section {
            if let c = current { LabeledContent(LS("当前下次扣费"), value: c) }
            DateRow(title: LS("调整为"), day: $draft.next)
        }
    }

    @ViewBuilder private var fields: some View {
        if draft.mode == .change {
            Section { DateRow(title: LS("生效日期"), day: $draft.date) }
        }
        Section {
            TextField(LS("名称"), text: $draft.name, prompt: Text(LS("如 iCloud+、Netflix"))).disabled(draft.mode == .change)
            LabeledContent(LS("金额")) {
                HStack {
                    TextField("", text: $draft.amount, prompt: Text("0.00")).monospacedDigit().multilineTextAlignment(.trailing)
                    TextField("", text: $draft.currency, prompt: Text("CNY")).frame(width: 56)
                }
            }
            TextField(LS("收付款方"), text: $draft.payee, prompt: Text(LS("可选")))
        }
        Section(LS("扣费周期")) {
            Picker(LS("周期"), selection: Binding(get: { draft.custom ? nil : draft.period }, set: { value in
                if let value { draft.period = value; draft.custom = false } else { draft.custom = true }
            })) {
                ForEach(SubPeriod.presets, id: \.self) { Text($0.name).tag(Optional($0)) }
                Text(LS("自定义")).tag(SubPeriod?.none)
            }
            if draft.custom {
                Stepper(LS("每 %@", draft.period.n), value: $draft.period.n, in: 1...365)
                Picker(LS("单位"), selection: $draft.period.unit) {
                    Text(LS("天")).tag(PeriodUnit.day)
                    Text(LS("周")).tag(PeriodUnit.week)
                    Text(LS("月")).tag(PeriodUnit.month)
                    Text(LS("年")).tag(PeriodUnit.year)
                }
                .pickerStyle(.segmented)
            }
            if draft.mode != .change { DateRow(title: LS("首次扣费"), day: $draft.start) }
            Picker(LS("续费方式"), selection: $draft.manual) {
                Text(LS("自动扣费")).tag(false)
                Text(LS("手动续费")).tag(true)
            }
            Toggle(LS("金额不固定（按量计费）"), isOn: $draft.variable)
            Toggle(LS("免费试用"), isOn: $draft.trial)
            if draft.trial { DateRow(title: LS("试用结束"), day: $draft.trialEnd) }
            Toggle(LS("赠送 / 延长周期"), isOn: $draft.extended)
                .onChange(of: draft.extended) { _, on in
                    let from = draft.mode == .change ? draft.date : draft.start
                    if on, draft.next <= from { draft.next = draft.period.add(from, 1) }
                }
            if draft.extended { DateRow(title: LS("下次扣费日"), day: $draft.next) }
        }
        Section {
            AccountField(title: LS("支出科目"), prefixes: ["Expenses:"], derived: derived, account: $draft.account)
            AccountField(title: LS("付款账户"), prefixes: ["Liabilities:", "Assets:"], derived: derived, account: $draft.funding)
            if draft.mode == .new && !draft.txns.isEmpty {
                LabeledContent(LS("关联交易"), value: LS("%@ 笔", draft.picked.count))
            }
        }
    }

    private func save() {
        writer.prepare(.save(draft), step: step) { dismiss() }
    }
}

/// 暂停 and 取消订阅: from a day on, and for a cancelled plan the day it can still be used to
struct SubscriptionStateEditor: View {
    let name: String
    let status: SubStatus
    let folder: URL
    @State private var date = Day.today()
    @State private var keepUntil = true
    @State private var until: String
    @State private var busy = false
    @State private var message = ""
    @State private var review: FolderSave?
    @Environment(\.dismiss) private var dismiss

    init(sub: Subscription, status: SubStatus, folder: URL) {
        name = sub.name
        self.status = status
        self.folder = folder
        let today = Day.today()
        _until = State(initialValue: sub.lastCharge.map { max(Day.shift(sub.period.add($0.date, 1), -1), today) } ?? today)
    }

    private var writer: SubscriptionWriter { SubscriptionWriter(folder: folder, busy: $busy, message: $message, review: $review) }

    private var text: String {
        subscriptionStateText(name, status, date: date, until: status == .cancelled && keepUntil ? until : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(status == .paused ? LS("暂停订阅") : LS("取消订阅")).font(.headline)
                Spacer()
                Button(LS("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(LS("保存")) {
                    writer.prepare(.state(name: name, status, date: date, until: status == .cancelled && keepUntil ? until : nil), step: step) { dismiss() }
                }
                .keyboardShortcut(.defaultAction).disabled(busy)
            }
            .padding(16)
            Form {
                DateRow(title: LS("生效日期"), day: $date)
                if status == .cancelled {
                    Toggle(LS("本期仍可使用"), isOn: $keepUntil)
                    if keepUntil { DateRow(title: LS("可用至"), day: $until) }
                }
                DisclosureGroup(LS("将写入")) {
                    Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .disabled(busy)
            Text(message).font(.callout).foregroundStyle(Color.loss).lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).padding(.horizontal, 16)
        }
        .frame(width: 480, height: 340)
        .interactiveDismissDisabled(busy)
        .subscriptionReview(writer, $review, step: step) { dismiss() }
    }

    private var step: String { status == .paused ? LS("暂停订阅") : LS("取消订阅") }
}
