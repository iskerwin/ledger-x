import Foundation

/// The tap felt with a notice, as it comes on screen.
public enum ToastFeedback: Sendable {
    /// something went wrong or was refused: it looks and feels different, and stays longer to be read
    case success, selection, failure
}

/// One line of transient feedback. An action (such as 撤销) stays up longer than plain text.
public struct ToastNotice: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var action: String?
    public var feedback: ToastFeedback?

    public init(id: UUID = UUID(), text: String, action: String? = nil, feedback: ToastFeedback? = nil) {
        self.id = id
        self.text = text
        self.action = action
        self.feedback = feedback
    }

    public var duration: TimeInterval {
        action != nil ? ToastSchedule.undo : feedback == .failure ? ToastSchedule.failure : ToastSchedule.plain
    }
}

/// When a toast may appear, and how long it stays once it is actually on screen.
///
/// The clock does not run while `busy` is true, and a save can ask to wait out the
/// card dismissal before the first frame. A later notice waits behind the one on screen.
public struct ToastSchedule: Equatable, Sendable {
    public static let plain: TimeInterval = 3
    public static let undo: TimeInterval = 6
    /// a failure says what happened and what is kept: a little longer than plain text
    public static let failure: TimeInterval = 5
    /// Long enough for the 记一笔 sheet to leave. The countdown starts after this, not during it.
    public static let settle: TimeInterval = 0.5

    public private(set) var visible: ToastNotice?
    public private(set) var queued: [ToastNotice] = []
    private var elapsed: TimeInterval = 0
    private var tickingFrom: Date?
    private var presentAfter: Date?
    private var busy = false
    private var unannounced: UUID?

    public init() {}

    public var isQuiescent: Bool {
        visible == nil && queued.isEmpty && presentAfter == nil
    }

    /// `settle` holds the notice until the card has finished closing. It does not replace a notice
    /// that is already counting down.
    public mutating func enqueue(_ notice: ToastNotice, now: Date, settle: Bool) {
        if visible != nil || !queued.isEmpty || presentAfter != nil {
            queued.append(notice)
            return
        }
        if settle {
            queued.append(notice)
            presentAfter = now.addingTimeInterval(Self.settle)
            return
        }
        begin(notice, now: now)
    }

    /// Pass the current rebuild flag on each tick. Busy time is not part of the countdown.
    @discardableResult
    public mutating func setBusy(_ busy: Bool, now: Date) -> Bool {
        guard busy != self.busy else {
            if !busy { return advance(now: now) }
            return false
        }
        if busy {
            // The time since the last idle tick may already be the blocked rebuild.
            // Leave it out; the countdown keeps the time recorded while the page was idle.
            tickingFrom = nil
            self.busy = true
            return false
        }
        self.busy = false
        if visible != nil, tickingFrom == nil { tickingFrom = now }
        return advance(now: now)
    }

    @discardableResult
    public mutating func advance(now: Date) -> Bool {
        var changed = false
        if let visible, !busy {
            account(until: now)
            if elapsed >= visible.duration {
                self.visible = nil
                elapsed = 0
                tickingFrom = nil
                changed = true
            }
        }
        if self.visible == nil, !busy {
            if let presentAfter, now < presentAfter { return changed }
            guard !queued.isEmpty else {
                self.presentAfter = nil
                return changed
            }
            let next = queued.removeFirst()
            self.presentAfter = nil
            begin(next, now: now)
            changed = true
        }
        return changed
    }

    /// The notice that has just come on screen, once: its feedback is felt now, with the notice, not when it was
    /// queued (a save waits for the card to close first).
    public mutating func announce() -> ToastNotice? {
        guard let visible, visible.id == unannounced else { return nil }
        unannounced = nil
        return visible
    }

    /// The user took the action, or the notice was cleared. The next queued notice can come up.
    public mutating func dismissVisible(now: Date) {
        guard visible != nil else { return }
        visible = nil
        elapsed = 0
        tickingFrom = nil
        _ = advance(now: now)
    }

    private mutating func begin(_ notice: ToastNotice, now: Date) {
        visible = notice
        unannounced = notice.id
        elapsed = 0
        tickingFrom = busy ? nil : now
    }

    private mutating func account(until now: Date) {
        guard let tickingFrom else { return }
        let dt = now.timeIntervalSince(tickingFrom)
        if dt > 0 { elapsed += dt }
        self.tickingFrom = now
    }
}
