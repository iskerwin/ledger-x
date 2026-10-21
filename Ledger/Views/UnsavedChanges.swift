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
            var node = parent
            while let current = node {
                // Contained controllers can report their ancestor's presenter. Only install on
                // the controller actually presented, rather than a child's unused presentation.
                if let presenter = current.presentingViewController,
                   presenter.presentedViewController === current {
                    install(on: current)
                    return
                }
                node = current.parent
            }
            // SwiftUI may introduce an additional presentation host outside our parent chain.
            var presented = view.window?.rootViewController?.presentedViewController
            while let current = presented {
                if view.isDescendant(of: current.view) { install(on: current); return }
                presented = current.presentedViewController
            }
        }

        private func install(on controller: UIViewController) {
            guard let presentation = controller.presentationController, presentation.delegate !== self else { return }
            detach()
            guarded = presentation
            previous = presentation.delegate
            presentation.delegate = self
        }

        func detach() {
            if let guarded = guarded, guarded.delegate === self { guarded.delegate = previous }
            guarded = nil; previous = nil
        }
        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !blocked && (previous?.presentationControllerShouldDismiss?(presentationController) ?? true)
        }
        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            guard blocked else {
                previous?.presentationControllerDidAttemptToDismiss?(presentationController)
                return
            }
            // Present the confirmation after the cancelled drag has settled.
            if let transition = presentationController.presentedViewController.transitionCoordinator,
               transition.animate(alongsideTransition: nil, completion: { [weak self] _ in self?.attempt() }) {
                return
            }
            DispatchQueue.main.async { [weak self] in self?.attempt() }
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
                // A cancel-role action is omitted when this dialog is shown as a popover
                // (a sheet presenting another confirmation). Keep it as a normal button so
                // 「继续编辑」is actually on screen.
                Button { confirming = false } label: { Text(LS("继续编辑")) }
                if let keep = keep { Button(action: keep) { Text(LS("保留草稿并关闭")) } }
                Button(role: .destructive, action: discard) { Text(LS("放弃修改并关闭")) }
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
