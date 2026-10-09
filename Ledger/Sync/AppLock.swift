import Foundation
import LocalAuthentication
import SwiftUI

/// Face ID / Touch ID / passcode lock, on launch and after the app has been in the background
@MainActor
final class AppLock: ObservableObject {
    static let enabledKey = "ledger.lock"
    static let graceKey = "ledger.lockGrace"

    @Published private(set) var locked: Bool
    @Published private(set) var authenticating = false
    @Published var lastError: String?
    private var backgroundAt: Date?

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var grace: TimeInterval { TimeInterval(UserDefaults.standard.integer(forKey: Self.graceKey)) }

    init() {
        let demo = ProcessInfo.processInfo.environment["LEDGER_DEMO"] != nil
        locked = !demo && UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func scenePhase(_ p: ScenePhase) {
        switch p {
        case .background:
            if backgroundAt == nil { backgroundAt = Date() }
            if enabled && grace == 0 { locked = true }
        case .active:
            if !enabled { locked = false; backgroundAt = nil; return }
            if let t = backgroundAt, Date().timeIntervalSince(t) >= grace { locked = true }
            backgroundAt = nil
            if locked { Task { await unlock() } }
        default: break
        }
    }

    func unlock() async {
        guard locked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = LS("输入密码")
        var err: NSError?
        // no passcode on the device: nothing to authenticate with, don't lock the user out
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { locked = false; return }
        do {
            if try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: LS("解锁以查看账本")) {
                withAnimation(.easeOut(duration: 0.2)) { locked = false }
                lastError = nil
            }
        } catch {
            lastError = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
        }
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
        VStack(spacing: 18) {
            Spacer()
            Image("Logo").resizable().frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(LS("Ledger 已锁定")).font(.title3.weight(.semibold))
            if let e = lock.lastError { Text(e).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal) }
            Spacer()
            Button {
                Task { await lock.unlock() }
            } label: {
                Label(LS("使用%@解锁", b.name), systemImage: b.symbol)
                    .font(.headline)
                    .frame(maxWidth: 280)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(lock.authenticating)
            .padding(.bottom, 48)
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
