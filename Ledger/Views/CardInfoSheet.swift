import SwiftUI
import UIKit
import UniformTypeIdentifiers
import LocalAuthentication
import LedgerKit

/// Face ID / Touch ID / the passcode before a card is shown or changed; interface tests (demo) pass straight through
enum CardAuth {
    enum Outcome { case ok, cancelled, unavailable }
    static var verify: () async -> Outcome = {
        if ProcessInfo.processInfo.environment["LEDGER_DEMO"] != nil { return .ok }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = LS("输入密码")
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return .unavailable }
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: LS("查看卡片信息"))) ?? false
        return ok ? .ok : .cancelled
    }
}

/// 长按卡面 → 卡片信息: a bank or credit card's number, expiry, security code and holder, kept in this phone's
/// keychain (`CardVault`), never in the ledger. Shown only after Face ID or the passcode, hidden again after 30
/// seconds or when the app leaves the screen; a field copied stays on this phone's clipboard for 60 seconds.
struct CardInfoSheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let account: String
    let title: String

    @State private var saved: CardInfo?
    @State private var loaded = false
    @State private var revealed = false
    @State private var editing = false
    @State private var draft = CardInfo()
    @State private var number = ""
    @State private var expiry = ""
    @State private var copied: String?
    @State private var note: String?
    @State private var confirmDelete = false
    @State private var hideToken = 0
    /// Face ID's own panel takes the app off the screen for a moment: not a reason to hide the card
    @State private var authenticating = false
    /// the app is on its way off the screen (the app switcher): nothing shows in its snapshot
    @State private var covered = false

    static let shownFor: Duration = .seconds(30)
    static let clipboardFor: TimeInterval = 60

    var body: some View {
        NavigationStack {
            Form {
                if covered { EmptyView() } else if editing { editForm } else if let saved { shownForm(saved) }
            }
            .navigationTitle(LS("卡片信息"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if editing && saved != nil {
                        Button { editing = false } label: { Label(LS("取消"), systemImage: "xmark").labelStyle(ControlLabelStyle()) }
                    } else {
                        Button { dismiss() } label: { Label(editing ? LS("取消") : LS("完成"), systemImage: editing ? "xmark" : "checkmark").labelStyle(ControlLabelStyle()) }
                            .accessibilityIdentifier("cardinfo.close")
                    }
                }
                if editing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { save() } label: { SaveLabel() }
                            .disabled(!canSave)
                            .accessibilityIdentifier("cardinfo.save")
                    }
                }
            }
            .confirmationDialog(LS("删除这张卡的卡片信息？"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(role: .destructive) { remove() } label: { Text(LS("删除")) }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                saved = store.cardInfo(account)
                // nothing kept yet: straight to filling it in (nothing to reveal)
                if saved == nil { startEditing(CardInfo()) }
            }
            // out of sight (another app, the lock screen): nothing stays on screen; on the way there (the app
            // switcher) the contents are covered and shown values hidden again
            .onChange(of: scenePhase) { _, p in
                switch p {
                case .background: dismiss()
                case .inactive where !authenticating: covered = true; revealed = false; copied = nil
                default: covered = false
                }
            }
        }
        .formSheet()
    }

    // MARK: shown

    @ViewBuilder
    private func shownForm(_ c: CardInfo) -> some View {
        let masked = KitPrivacy.masked
        let showing = revealed && !masked
        Section {
            row(LS("卡号"), id: "number", showing: showing, value: c.number.isEmpty ? nil : groupedCardNumber(c.number),
                hidden: c.last4.map { "•••• " + $0 } ?? "••••", copy: c.number)
            row(LS("有效期"), id: "expiry", showing: showing, value: c.expiry.isEmpty ? nil : c.expiry, hidden: "••/••", copy: c.expiry)
            row(LS("安全码"), id: "cvv", showing: showing, value: c.cvv.isEmpty ? nil : c.cvv, hidden: "•••", copy: c.cvv)
            row(LS("持卡人"), id: "holder", showing: showing, value: c.holder.isEmpty ? nil : c.holder, hidden: "••••", copy: c.holder)
        } header: {
            Text(title)
        } footer: {
            // every line it can say laid over one another, one seen: the buttons under it stay put on 显示 / 隐藏
            let lines = [LS("卡片信息只存在这台手机的钥匙串里，不写进账本，也不随备份或 iCloud 同步。查看和修改要先验证面容 ID 或密码。"),
                         LS("30 秒后或离开 App 时自动隐藏。复制的内容只留在这台手机的剪贴板，60 秒后清除。"),
                         LS("隐私模式下不显示卡片信息。")] + (note.map { [$0] } ?? [])
            let current = note ?? (masked ? lines[2] : showing ? lines[1] : lines[0])
            ZStack(alignment: .topLeading) {
                ForEach(lines, id: \.self) { t in
                    Text(t).opacity(t == current ? 1 : 0).accessibilityHidden(t != current)
                }
            }
        }
        Section {
            Button {
                if showing { revealed = false } else { Task { await reveal() } }
            } label: {
                Label(showing ? LS("隐藏") : LS("显示"), systemImage: showing ? "eye.slash" : "eye").labelStyle(ControlLabelStyle())
            }
            .disabled(masked)
            .accessibilityIdentifier("cardinfo.reveal")
            Button {
                Task {
                    let ok = showing ? true : await verified()
                    if ok { startEditing(c) }
                }
            } label: {
                Label(LS("编辑"), systemImage: "pencil").labelStyle(ControlLabelStyle())
            }
            .disabled(masked)
            .accessibilityIdentifier("cardinfo.edit")
            Button(role: .destructive) { confirmDelete = true } label: {
                Label(LS("删除卡片信息"), systemImage: "trash").labelStyle(ControlLabelStyle())
            }
            .accessibilityIdentifier("cardinfo.delete")
        }
    }

    private func row(_ name: String, id: String, showing revealed: Bool, value: String?, hidden: String, copy: String) -> some View {
        HStack(spacing: AppSpacing.control) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: AppSpacing.icon)
            if let value {
                Text(revealed ? value : hidden).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityIdentifier("cardinfo." + id)
                // there while hidden too, only not seen: the row keeps its height from one to the other
                Button { copyValue(copy, id: id) } label: {
                    Image(systemName: copied == id ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .opacity(revealed ? 1 : 0)
                .disabled(!revealed)
                .accessibilityHidden(!revealed)
                .accessibilityLabel(LS("复制%@", name))
                .accessibilityIdentifier("cardinfo.copy." + id)
            } else {
                Text(LS("未填写")).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: editing

    @ViewBuilder
    private var editForm: some View {
        let digits = cardDigits(number)
        Section {
            TextField(LS("卡号"), text: Binding { number } set: { number = groupedCardNumber(cardDigits($0)) })
                .keyboardType(.numberPad).textContentType(.creditCardNumber).monospacedDigit()
                .accessibilityIdentifier("cardinfo.field.number")
            TextField(LS("有效期（月/年，如 06/28）"), text: $expiry)
                .keyboardType(.numbersAndPunctuation).monospacedDigit()
                .accessibilityIdentifier("cardinfo.field.expiry")
            TextField(LS("安全码（卡背面 3 或 4 位）"), text: Binding { draft.cvv } set: { draft.cvv = String($0.filter { $0.isASCII && $0.isNumber }.prefix(4)) })
                .keyboardType(.numberPad).monospacedDigit()
                .accessibilityIdentifier("cardinfo.field.cvv")
            TextField(LS("持卡人"), text: $draft.holder)
                .textContentType(.name).autocorrectionDisabled()
                .accessibilityIdentifier("cardinfo.field.holder")
        } header: {
            Text(title)
        } footer: {
            if let problem = problem(digits) {
                Text(problem).foregroundStyle(Color.loss)
            } else if !digits.isEmpty && !cardNumberValid(digits) {
                Text(LS("卡号的校验位对不上，可能输错了一位；确认无误也可以保存。")).foregroundStyle(Color.warn)
            } else {
                Text(LS("都可以不填。只存在这台手机的钥匙串里，不写进账本，也不随备份或 iCloud 同步；卡面上显示卡号后 4 位和有效期。"))
            }
        }
    }

    /// what keeps the card from being saved, in words
    private func problem(_ digits: String) -> String? {
        if !digits.isEmpty && digits.count < 12 { return LS("卡号至少 12 位。") }
        if !expiry.trimmingCharacters(in: .whitespaces).isEmpty && normalizedExpiry(expiry) == nil { return LS("有效期写成 月/年，如 06/28。") }
        if !draft.cvv.isEmpty && !cvvValid(draft.cvv) { return LS("安全码是 3 或 4 位数字。") }
        return nil
    }

    private var canSave: Bool { problem(cardDigits(number)) == nil }

    private func startEditing(_ c: CardInfo) {
        draft = c
        number = groupedCardNumber(c.number)
        expiry = c.expiry
        editing = true
    }

    private func save() {
        var c = draft
        c.number = cardDigits(number)
        c.expiry = normalizedExpiry(expiry) ?? ""
        c.holder = c.holder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.setCardInfo(c, for: account) else {
            note = LS("这台手机的钥匙串没有存下，卡片信息没有保存。")
            return
        }
        Haptics.success()
        if c.isEmpty { dismiss(); return }
        saved = c
        editing = false
        note = nil
        show()
    }

    private func remove() {
        guard store.setCardInfo(CardInfo(), for: account) else {
            note = LS("这台手机的钥匙串没有删掉，请再试一次。")
            return
        }
        dismiss()
    }

    // MARK: showing

    private func verified() async -> Bool {
        authenticating = true
        defer { authenticating = false }
        switch await CardAuth.verify() {
        case .ok: note = nil; return true
        case .cancelled: return false
        case .unavailable:
            note = LS("这台 iPhone 没有设置密码，不能查看卡片信息。请在系统「设置 › 面容 ID 与密码」里设置密码。")
            return false
        }
    }

    private func reveal() async {
        guard await verified() else { return }
        show()
    }

    /// shown for 30 seconds from now (a later reveal starts its own 30 seconds)
    private func show() {
        revealed = true
        hideToken += 1
        let token = hideToken
        Task {
            try? await Task.sleep(for: Self.shownFor)
            if token == hideToken { revealed = false; copied = nil }
        }
    }

    private func copyValue(_ value: String, id: String) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: value]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(Self.clipboardFor)])
        copied = id
        Haptics.success()
    }
}
