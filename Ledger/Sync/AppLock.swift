import Foundation
import LocalAuthentication
import SwiftUI
import LedgerKit

/// Face ID / Touch ID / passcode lock, on launch and after the app has been in the background
@MainActor
final class AppLock: ObservableObject {
    static let enabledKey = "ledger.lock"
    static let graceKey = "ledger.lockGrace"

    @Published private(set) var locked: Bool
    @Published private(set) var authenticating = false
    @Published var lastError: String?
    /// biometry failed or was cancelled: the lock screen offers the device passcode directly
    @Published private(set) var offerPasscode = false
    private var gate: LockGate

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var grace: TimeInterval { TimeInterval(UserDefaults.standard.integer(forKey: Self.graceKey)) }

    init() {
        let demo = ProcessInfo.processInfo.environment["LEDGER_DEMO"] != nil
        let on = !demo && UserDefaults.standard.bool(forKey: Self.enabledKey)
        locked = on
        gate = LockGate(enabled: false, grace: 0, locked: on)
    }

    /// asks by itself only on a return from the background: the Face ID panel's own inactive → active does not ask again
    func scenePhase(_ p: ScenePhase) {
        let phase: LockPhase
        switch p {
        case .background: phase = .background
        case .active: phase = .active
        default: phase = .inactive
        }
        gate.enabled = enabled
        gate.grace = grace
        let ask = gate.phase(phase, now: Date())
        if gate.locked != locked { locked = gate.locked }
        if ask { Task { await unlock() } }
    }

    /// passcode: skip biometry and ask for the device passcode straight away
    func unlock(passcode: Bool = false) async {
        guard locked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = LS("输入密码")
        // the passcode was taken off the phone after the lock was turned on: stay locked (letting anyone in would
        // make the lock pointless) and say how to get back in
        guard Self.canAuthenticate(ctx) else {
            lastError = LS("这台 iPhone 没有设置密码，无法解锁。请在系统「设置 › 面容 ID 与密码」里设置密码后再打开。")
            return
        }
        let reason = LS("解锁以查看账本")
        do {
            let ok = passcode
                ? try await Self.passcodeOnly(ctx, reason: reason)
                : try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok {
                gate.unlock()
                withAnimation(.easeOut(duration: 0.2)) { locked = false }
                lastError = nil
                offerPasscode = false
            }
        } catch {
            let code = (error as? LAError)?.code
            // Face ID only offers the passcode after a second failure; once it fails or is cancelled, offer it here
            if code != .systemCancel && code != .appCancel { offerPasscode = true }
            lastError = code == .userCancel || code == .systemCancel ? nil : error.localizedDescription
        }
    }

    /// whether the phone has anything to authenticate with (a passcode); tests stand in a phone without one
    static var canAuthenticate: (LAContext) -> Bool = { ctx in
        var err: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
    }

    /// the device passcode alone, without trying biometry first
    private static func passcodeOnly(_ ctx: LAContext, reason: String) async throws -> Bool {
        guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .devicePasscode, nil)
        else { return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) }
        return try await ctx.evaluateAccessControl(acl, operation: .useItem, localizedReason: reason)
    }

    /// confirm before turning the lock on or off
    static func verify(_ reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// what the device offers: name and SF Symbol
    static var biometry: (name: String, symbol: String, available: Bool) {
        let ctx = LAContext()
        var err: NSError?
        let any = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return (LS("面容 ID"), "faceid", any)
        case .touchID: return (LS("触控 ID"), "touchid", any)
        case .opticID: return (LS("视控 ID"), "opticid", any)
        default: return (LS("设备密码"), "lock", any)
        }
    }
}

struct LockScreen: View {
    @EnvironmentObject var lock: AppLock
    var body: some View {
        let b = AppLock.biometry
        // the logo high up: the system's Face ID panel shows in the middle of the screen
        VStack(spacing: AppSpacing.content) {
            Spacer().frame(height: 96)
            Image("Logo").resizable().frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(LS("Ledger X 已锁定")).font(.title3.weight(.semibold))
            if let e = lock.lastError { Text(e).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, AppSpacing.content) }
            Spacer()
            Button {
                Task { await lock.unlock() }
            } label: {
                Label(LS("使用%@解锁", b.name), systemImage: b.symbol).labelStyle(ControlLabelStyle())
                    .font(.headline)
                    .frame(maxWidth: 280)
                    .padding(.vertical, AppSpacing.icon)
            }
            .primaryButton()
            .disabled(lock.authenticating)
            .padding(.bottom, lock.offerPasscode && b.symbol != "lock" ? 0 : 48)
            if lock.offerPasscode && b.symbol != "lock" {
                Button(LS("使用%@解锁", LS("设备密码"))) {
                    Task { await lock.unlock(passcode: true) }
                }
                .font(.subheadline)
                .disabled(lock.authenticating)
                .accessibilityIdentifier("unlockWithPasscode")
                .padding(.bottom, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

/// covers the screen in the app switcher
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            Image("Logo").resizable().frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }
}
