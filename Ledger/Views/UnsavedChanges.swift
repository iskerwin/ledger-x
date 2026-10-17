import SwiftUI
import UIKit

/// Keep SwiftUI's presentation delegate while intercepting an attempted swipe-to-dismiss.
private struct DismissAttempt: UIViewControllerRepresentable {
    let blocked: Bool
    let attempt: () -> Void

    func makeUIViewController(context: Context) -> GuardController { GuardController() }
    func updateUIViewController(_ controller: GuardController, context: Context) {
        controller.blocked = blocked
        controller.attempt = attempt
        DispatchQueue.main.async { [weak controller] in controller?.attach() }
    }
    static func dismantleUIViewController(_ controller: GuardController, coordinator: ()) { controller.detach() }

    final class GuardController: UIViewController, UIAdaptivePresentationControllerDelegate {
        var blocked = false
        var attempt: () -> Void = {}
        private weak var guarded: UIPresentationController?
        private weak var previous: UIAdaptivePresentationControllerDelegate?

        override func viewDidLoad() { super.viewDidLoad(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); attach() }

        func attach() {
            var node: UIViewController? = self
            while let current = node {
                if current.presentingViewController != nil, let presentation = current.presentationController {
                    if presentation.delegate !== self {
                        detach()
                        guarded = presentation
                        previous = presentation.delegate
                        presentation.delegate = self
                    }
                    return
                }
                node = current.parent
            }
        }

        func detach() {
            if let guarded = guarded, guarded.delegate === self { guarded.delegate = previous }
            guarded = nil; previous = nil
        }
        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !blocked && (previous?.presentationControllerShouldDismiss?(presentationController) ?? true)
        }
        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if blocked { attempt() }
            else { previous?.presentationControllerDidAttemptToDismiss?(presentationController) }
        }
        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            previous?.presentationControllerWillDismiss?(presentationController)
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            previous?.presentationControllerDidDismiss?(presentationController)
        }
    }
}

private struct UnsavedChanges: ViewModifier {
    let dirty: Bool
    let busy: Bool
    @Binding var requested: Bool
    var keep: (() -> Void)?
    let discard: () -> Void
    let close: () -> Void
    @State private var confirming = false

    func body(content: Content) -> some View {
        content
            .background(DismissAttempt(blocked: dirty || busy) {
                if !busy { requested = true }
            }.frame(width: 0, height: 0))
            .onChange(of: requested) { _, value in
                guard value else { return }
                requested = false
                guard !busy else { return }
                if dirty { confirming = true; Haptics.warning() } else { close() }
            }
            .confirmationDialog(LS("还有未保存的修改"), isPresented: $confirming, titleVisibility: .visible) {
                Button(LS("继续编辑"), role: .cancel) {}
                if let keep = keep { Button(LS("保留草稿并关闭"), action: keep) }
                Button(LS("放弃修改并关闭"), role: .destructive, action: discard)
            } message: {
                Text(keep == nil ? LS("关闭将放弃本次未保存的修改。") : LS("草稿仅保存在本机，不会写入账本。"))
            }
    }
}

extension View {
    func protectUnsavedChanges(dirty: Bool, busy: Bool = false, requested: Binding<Bool>,
                               keep: (() -> Void)? = nil, discard: @escaping () -> Void,
                               close: @escaping () -> Void) -> some View {
        modifier(UnsavedChanges(dirty: dirty, busy: busy, requested: requested,
                                keep: keep, discard: discard, close: close))
    }
}
