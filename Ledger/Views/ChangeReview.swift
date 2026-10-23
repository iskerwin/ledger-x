import SwiftUI
import UIKit
import LedgerKit

enum ReviewChoice { case edit, force, hold }

/// the pre-commit check sheet; presented from UIKit so it can sit on top of whatever sheet is open
@MainActor
enum ChangeReview {
    static func ask(_ issues: [ChangeIssue]) async -> ReviewChoice {
        // a sheet that is still opening or closing can't present anything: wait for its transition
        while let tc = transitionInProgress() {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                tc.animate(alongsideTransition: nil) { _ in c.resume() }
            }
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<ReviewChoice, Never>) in
            guard let top = topController() else { cont.resume(returning: .edit); return }
            final class Box { var host: UIViewController?; var done = false }
            let box = Box()
            let view = ChangeReviewView(issues: issues) { choice in
                guard !box.done else { return }
                box.done = true
                // resume once the sheet is gone, so the caller can dismiss its own sheet right away
                if let h = box.host, h.presentingViewController != nil {
                    h.dismiss(animated: true) { cont.resume(returning: choice) }
                } else {
                    cont.resume(returning: choice)
                }
            }
            .tint(Color.jade)
            let host = UIHostingController(rootView: view)
            host.isModalInPresentation = true
            if let s = host.sheetPresentationController {
                s.detents = [.medium(), .large()]
                s.prefersGrabberVisible = true
            }
            box.host = host
            top.present(host, animated: true)
            // UIKit refuses (and never calls back) when it can't present; then the caller goes back to editing
            if host.presentingViewController == nil, !box.done { box.done = true; cont.resume(returning: .edit) }
        }
    }

    /// the transition of a view controller in the key window being presented or dismissed, if any
    private static func transitionInProgress() -> UIViewControllerTransitionCoordinator? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var vc = (scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first)?.rootViewController
        while let v = vc {
            if let tc = v.transitionCoordinator { return tc }
            vc = v.presentedViewController
        }
        return nil
    }

    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let win = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var vc = win?.rootViewController
        while let p = vc?.presentedViewController, !p.isBeingDismissed { vc = p }
        if let v = vc, v.isBeingDismissed { return v.presentingViewController }
        return vc
    }
}

struct ChangeReviewView: View {
    let issues: [ChangeIssue]
    let choose: (ReviewChoice) -> Void
    private var blocked: Bool { issues.contains { $0.blocking } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(issues) { i in
                        HStack(alignment: .top, spacing: AppSpacing.icon) {
                            IconBadge(symbol: symbol(i.kind), color: color(i.kind), size: 28)
                            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                                Text(i.title).font(.subheadline.weight(.semibold))
                                if !i.detail.isEmpty { Text(i.detail).font(.caption).foregroundStyle(.secondary).sensitive() }
                            }
                        }
                        .padding(.vertical, AppSpacing.detail)
                    }
                } header: {
                    Text(LS("发现 %@ 个问题", issues.count))
                } footer: {
                    if blocked {
                        Text(LS("账户的开户日期、关户日期或允许的币种不符，bean-check 一定会拒绝，不能直接提交；请返回修改账户、日期或币种。"))
                    } else {
                        Text(LS("这些问题由本次修改引起。直接提交会让 bean-check 报错；请检查账户和金额是否填对。"))
                    }
                }
            }
            .navigationTitle(LS("提交前检查"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: AppSpacing.control) {
                    ActionRow(size: .large, items: [
                        ActionRow.Item(title: LS("返回修改"), systemImage: "pencil", emphasis: .primary) { choose(.edit) },
                    ])
                    // an account used outside its open line is rejected whatever the reason: it can wait, not go
                    ActionRow(size: .large, items: [ActionRow.Item(title: LS("暂存本机"), systemImage: "internaldrive") { choose(.hold) }]
                              + (blocked ? [] : [ActionRow.Item(title: LS("仍然提交"), systemImage: "exclamationmark.triangle", emphasis: .destructive) { choose(.force) }]))
                    Text(LS("暂存的修改不会推送，可在 设置 →「同步与最近改动」→「待同步」中确认后推送或移除。"))
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, AppSpacing.content)
                .padding(.vertical, AppSpacing.icon)
                .background(.bar)
            }
        }
    }

    private func symbol(_ k: ChangeIssue.Kind) -> String {
        switch k {
        case .balance: return "checkmark.seal"
        case .error: return "exclamationmark.triangle"
        case .insufficient: return "banknote"
        case .creditLimit: return "creditcard"
        }
    }

    private func color(_ k: ChangeIssue.Kind) -> Color {
        switch k {
        case .balance, .error: return .loss
        case .insufficient, .creditLimit: return .warn
        }
    }
}
