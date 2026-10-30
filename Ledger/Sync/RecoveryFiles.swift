import Foundation
import CryptoKit
import LedgerKit

/// Private, per-ledger recovery copies; never included in ledger text or public diagnostics.
@MainActor
enum RecoveryFiles {
    private static func url(_ kind: String, ledger: String, ext: String = "json") throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(ledger.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(kind + "-" + key + "." + ext)
    }
    static func load<T: Decodable>(_ type: T.Type, kind: String, ledger: String) -> T? {
        guard let path = try? url(kind, ledger: ledger), let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, kind: String, ledger: String) throws {
        try JSONEncoder().encode(value).write(to: url(kind, ledger: ledger), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func loadData(kind: String, ledger: String) -> Data? {
        guard let path = try? url(kind, ledger: ledger, ext: "bin") else { return nil }
        return try? Data(contentsOf: path)
    }
    static func saveData(_ data: Data, kind: String, ledger: String) throws {
        try data.write(to: url(kind, ledger: ledger, ext: "bin"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func removeData(kind: String, ledger: String) throws {
        let path = try url(kind, ledger: ledger, ext: "bin")
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    static func remove(kind: String, ledger: String) throws {
        let path = try url(kind, ledger: ledger)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    /// A list or note read back the way `load` reads it, but telling apart what `load` takes for "nothing": a
    /// file that can't be opened yet (the phone not unlocked since it started) stays as it is, and one whose
    /// contents don't read back is moved aside as `<kind>-unreadable` (see `unreadable`). Either way the caller
    /// must not write an empty list over it.
    static func read<T: Decodable>(_ type: T.Type, kind: String, ledger: String, ext: String = "json") -> RecoveryRead<T> {
        guard let path = try? url(kind, ledger: ledger, ext: ext) else { return .unavailable }
        guard FileManager.default.fileExists(atPath: path.path) else { return .none }
        guard let data = try? Data(contentsOf: path) else { return .unavailable }
        if let value = try? JSONDecoder().decode(type, from: data) { return .value(value) }
        return setAside(kind: kind, ledger: ledger, ext: ext) ? .damaged : .unavailable
    }

    /// the file moved out of the way, never written over: a newer unreadable copy replaces an older one
    private static func setAside(kind: String, ledger: String, ext: String) -> Bool {
        guard let from = try? url(kind, ledger: ledger, ext: ext),
              let to = try? url(kind + unreadableSuffix, ledger: ledger, ext: ext) else { return false }
        try? FileManager.default.removeItem(at: to)
        return (try? FileManager.default.moveItem(at: from, to: to)) != nil
    }

    static let unreadableSuffix = "-unreadable"

    /// the copies set aside for a ledger, with where they are, for the sync page to share or discard
    static func unreadable(ledger: String) -> [UnreadableRecord] {
        UnreadableKind.allCases.compactMap { k in
            guard let path = try? url(k.rawValue + unreadableSuffix, ledger: ledger, ext: k.ext),
                  FileManager.default.fileExists(atPath: path.path) else { return nil }
            return UnreadableRecord(kind: k, url: path)
        }
    }

    static func removeUnreadable(kind: UnreadableKind, ledger: String) {
        if let path = try? url(kind.rawValue + unreadableSuffix, ledger: ledger, ext: kind.ext) { try? FileManager.default.removeItem(at: path) }
    }
}

enum RecoveryRead<T> {
    case none
    case value(T)
    /// there, but can't be opened now: left as it is
    case unavailable
    /// opened, but doesn't read back: moved aside
    case damaged
}

struct UnreadableRecord: Identifiable {
    let kind: UnreadableKind
    let url: URL
    var id: String { kind.rawValue }
}

/// the records that can be set aside unread, and what each is called on the sync page
enum UnreadableKind: String, CaseIterable {
    case pending, inflight, attachments
    case deletedAttachments = "deleted-attachments"
    var ext: String { self == .pending ? "bin" : "json" }
    var title: String {
        switch self {
        case .pending: return LS("待同步的改动")
        case .inflight: return LS("上次推送的记录")
        case .attachments: return LS("待上传的附件")
        case .deletedAttachments: return LS("已删除附件的恢复记录")
        }
    }
}

/// The sync queue of each ledger, in a file of its own written to a temporary file and swapped in. It used to be
/// kept in UserDefaults, which holds it whole in memory and reads it at every launch, and a whole-file write puts
/// the file's full text in the queue. The UserDefaults copy is moved over the first time.
@MainActor
enum PendingQueue {
    private static let kind = "pending"

    /// a file that can't be opened yet, or whose contents don't read back, is never taken for an empty queue:
    /// writing that over it lost every change not yet pushed
    static func read(ledger: String) -> RecoveryRead<[Op]> {
        switch RecoveryFiles.read([Op].self, kind: kind, ledger: ledger, ext: "bin") {
        case .none:
            let old = Prefs.get(Store.key(kind, ledger), [Op]())
            if (try? save(old, ledger: ledger)) != nil { Prefs.d.removeObject(forKey: "ledger." + Store.key(kind, ledger)) }
            return .value(old)
        case let read:
            return read
        }
    }

    static func save(_ ops: [Op], ledger: String) throws {
        try RecoveryFiles.saveData(JSONEncoder().encode(ops), kind: kind, ledger: ledger)
    }

    static func remove(ledger: String) {
        try? RecoveryFiles.removeData(kind: kind, ledger: ledger)
        Prefs.d.removeObject(forKey: "ledger." + Store.key(kind, ledger))
    }
}

/// The note of a push about to go out (InFlightPush) could not be written on the phone. The push waits: sent without
/// it, a crash once the host has the change would leave the next push to apply the same edits again.
struct SyncRecordError: LocalizedError {
    let underlying: Error
    var errorDescription: String? { LS("没能在手机上记下这次上传，稍后再试：%@", underlying.localizedDescription) }
}

/// A record the push depends on can't be read: it waits rather than risk writing the same edits twice
struct UnreadableRecordError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
