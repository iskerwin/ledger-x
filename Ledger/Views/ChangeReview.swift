import SwiftUI
import UIKit
import LedgerKit

enum ReviewChoice { case edit, force, hold }

/// the pre-commit check sheet; presented from UIKit so it can sit on top of whatever sheet is open
@MainActor
enum ChangeReview {
    static func ask(_ issues: [ChangeIssue]) async -> ReviewChoice {
        await withCheckedContinuation { (cont: CheckedContinuation<ReviewChoice, Never>) in
            guard let top = topController() else { cont.resume(returning: .edit); return }
            final class Box { var host: UIViewController?; var done = false }
            let box = Box()
            let view = ChangeReviewView(issues: issues) { choice in
                guard !box.done else { return }
                box.done = true
                box.host?.dismiss(animated: true)
                cont.resume(returning: choice)
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
        }
    }

    static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let win = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var vc = win?.rootViewController
        while let p = vc?.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }
}

struct ChangeReviewView: View {
    let issues: [ChangeIssue]
    let choose: (ReviewChoice) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(issues) { i in
                        HStack(alignment: .top, spacing: 12) {
                            IconBadge(symbol: symbol(i.kind), color: color(i.kind), size: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(i.title).font(.subheadline.weight(.semibold))
                                if !i.detail.isEmpty { Text(i.detail).font(.caption).foregroundStyle(.secondary).sensitive() }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(LS("发现 %@ 个问题", issues.count))
                } footer: {
                    Text(LS("这些问题由本次修改引起。直接提交会让 bean-check 报错；请检查账户和金额是否填对。"))
                }
            }
            .navigationTitle(LS("提交前检查"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button { choose(.edit) } label: {
                        Text(LS("返回修改")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    HStack(spacing: 10) {
                        Button { choose(.hold) } label: { Text(LS("暂存本机")).frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                        Button(role: .destructive) { choose(.force) } label: { Text(LS("仍然提交")).frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    Text(LS("暂存的修改不会推送，可在 设置 → 同步队列 中确认后推送或删除。"))
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
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
