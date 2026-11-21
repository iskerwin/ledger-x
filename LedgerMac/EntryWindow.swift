import SwiftUI
import AppKit
import LedgerKit

/// the ledger on screen, shared by the main window and the 记一笔 window
@Observable
final class OpenLedger {
    var folder: URL?
    var ledger: Ledger?
    var config: LedgerXConfig?
    /// what the 记一笔 window holds while it's up: one entry at a time
    var entry: EntryRequest?
}

/// a new entry or one to change, with the ledger it was asked from
struct EntryRequest {
    let id = UUID()
    let folder: URL
    let ledger: Ledger
    let config: LedgerXConfig?
    let editing: Draft?
}

/// 记一笔 in a window of its own, to move aside and look at the entries behind it
struct EntryWindow: View {
    static let id = "entry"
    @Environment(OpenLedger.self) private var open
    @State private var window: NSWindow?

    var body: some View {
        Group {
            if let request = open.entry {
                // the ledger as it reloads, while it's still the one this was asked from
                let live = open.folder == request.folder ? open.ledger : nil
                NewEntrySheet(ledger: live ?? request.ledger, config: live == nil ? request.config : open.config,
                              folder: request.folder, editing: request.editing) { open.entry = nil }
                    .id(request.id)
                    // the open ledger's category style as it is saved (from here or the phone)
                    .environment(\.categoryStyle, ((live == nil ? request.config : open.config)?.categories) ?? CategoryStyle())
            }
        }
        .background(WindowReader { window in
            self.window = window
            // closing goes through the card's ✕ or 取消, which asks before an unsaved entry is lost
            window.styleMask.remove([.closable, .miniaturizable])
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            window.isMovableByWindowBackground = true
            // brought back empty by the system after a relaunch
            if open.entry == nil { window.close() }
        })
        .onChange(of: open.entry == nil) { if open.entry == nil { window?.close() } }
    }

    /// a height that fits the screen's free space, so the window never runs under the Dock
    static func fitted(_ height: CGFloat) -> CGFloat {
        guard let free = NSScreen.main?.visibleFrame.height else { return height }
        return min(height, free - 40)
    }

}

extension View {
    /// a scroll view drawn as tall as the `fields` it holds (nothing before they are measured), or as the screen has room for
    /// beside `bars`, the rest of the window. Its scroller shows only when they don't fit: one that came and went would
    /// narrow the fields, wrap them anew and change their height, round and round
    func fittedScroll(_ fields: CGFloat, bars: CGFloat) -> some View {
        let room = max(0, EntryWindow.fitted(.greatestFiniteMagnitude) - bars)
        return frame(height: fields == 0 ? nil : min(fields, room))
            .scrollIndicators(fields <= room ? .never : .automatic)
    }

    /// the height of all a scroll view in here holds, for a window as tall as its content.
    /// macOS 14 can't tell it: nothing is reported there
    @ViewBuilder
    func onScrollContentHeight(_ action: @escaping (CGFloat) -> Void) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom } action: { _, height in
                action(height)
            }
        } else {
            self
        }
    }
    /// what was used before, dropping down under a text field as it is typed in; macOS 14 has no such list.
    /// `closed` once the field holds a known one whole (picked, or typed to the end): macOS keeps the list up while it has
    /// anything in it, and one picked still matches itself. Typing on opens it again
    @ViewBuilder
    func suggesting(_ items: [String], closed: Bool) -> some View {
        if #available(macOS 15, *) {
            let shown = closed ? [] : items
            textInputSuggestions {
                ForEach(shown, id: \.self) { Text($0).textInputCompletion($0) }
            }
        } else {
            self
        }
    }
}

extension View {
    /// 记一笔 in its window when `asked` turns on: a new entry, or `editing` to change; an entry already up comes forward as it is
    func opensEntry(when asked: Binding<Bool>, editing: Draft? = nil, ledger: Ledger, config: LedgerXConfig?, folder: URL) -> some View {
        modifier(EntryOpening(asked: asked, editing: editing, ledger: ledger, config: config, folder: folder))
    }
}

private struct EntryOpening: ViewModifier {
    @Binding var asked: Bool
    let editing: Draft?
    let ledger: Ledger
    let config: LedgerXConfig?
    let folder: URL
    @Environment(OpenLedger.self) private var open
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: asked, initial: true) {
            guard asked else { return }
            if open.entry == nil { open.entry = EntryRequest(folder: folder, ledger: ledger, config: config, editing: editing) }
            asked = false
            openWindow(id: EntryWindow.id)
        }
    }
}

/// the window a view is in, once it's in one
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Reader(found: found) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Reader: NSView {
        let found: (NSWindow) -> Void
        init(found: @escaping (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // after the window has taken its saved frame
            guard let window else { return }
            DispatchQueue.main.async { [found] in found(window) }
        }
    }
}

/// the keys typed in this view's window while no text field has them: `typed` gets the characters and says whether it took them
struct TypedKeys: NSViewRepresentable {
    let enabled: Bool
    let typed: (String) -> Bool

    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ view: Catcher, context: Context) {
        view.typed = enabled ? typed : nil
    }

    final class Catcher: NSView {
        var typed: ((String) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let typed = self.typed, let window = self.window, event.window === window,
                      !(window.firstResponder is NSText),
                      event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
                      let characters = event.charactersIgnoringModifiers, typed(characters) else { return event }
                return nil
            }
        }
    }
}

extension NSWindow {
    /// a window saved or opened bigger than the screen's free space shrinks into it, clear of the menu bar and the Dock
    func fitScreen() {
        guard let free = (screen ?? NSScreen.main)?.visibleFrame else { return }
        var fitted = frame
        fitted.size.width = min(fitted.width, free.width)
        fitted.size.height = min(fitted.height, free.height)
        fitted.origin.x = min(max(fitted.minX, free.minX), free.maxX - fitted.width)
        fitted.origin.y = min(max(fitted.minY, free.minY), free.maxY - fitted.height)
        if fitted != frame { setFrame(fitted, display: true) }
    }
}
