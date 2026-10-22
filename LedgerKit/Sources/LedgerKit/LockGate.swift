import Foundation

/// The app's scene phase, as the lock sees it.
public enum LockPhase: Sendable {
    case active, inactive, background
}

/// When the app lock locks, and when it asks for Face ID / Touch ID by itself.
///
/// It asks once on launch and once on each return from the background. The system's own
/// Face ID or passcode panel makes the app inactive and then active again: that round trip
/// does not ask again, so cancelling leaves the lock screen up for the user to choose.
public struct LockGate: Equatable, Sendable {
    public var enabled: Bool
    /// seconds in the background before it locks; 0 locks as soon as the app leaves
    public var grace: TimeInterval
    public private(set) var locked: Bool
    private var backgroundAt: Date?

    public init(enabled: Bool, grace: TimeInterval, locked: Bool) {
        self.enabled = enabled
        self.grace = grace
        self.locked = locked
    }

    /// Returns true when the app should ask to unlock now.
    public mutating func phase(_ p: LockPhase, now: Date) -> Bool {
        switch p {
        case .background:
            if backgroundAt == nil { backgroundAt = now }
            if enabled && grace == 0 { locked = true }
            return false
        case .active:
            guard enabled else { locked = false; backgroundAt = nil; return false }
            guard let t = backgroundAt else { return false }
            backgroundAt = nil
            if now.timeIntervalSince(t) >= grace { locked = true }
            return locked
        case .inactive:
            return false
        }
    }

    public mutating func unlock() {
        locked = false
    }
}
