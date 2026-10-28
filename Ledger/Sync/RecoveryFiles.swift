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
}

/// The sync queue of each ledger, in a file of its own written to a temporary file and swapped in. It used to be
/// kept in UserDefaults, which holds it whole in memory and reads it at every launch, and a whole-file write puts
/// the file's full text in the queue. The UserDefaults copy is moved over the first time.
enum PendingQueue {
    private static let kind = "pending"

    static func load(ledger: String) -> [Op] {
        if let data = RecoveryFiles.loadData(kind: kind, ledger: ledger) {
            if let ops = try? JSONDecoder().decode([Op].self, from: data) { return ops }
            // unreadable: kept aside instead of written over, and the old copy (if any) used
            try? RecoveryFiles.saveData(data, kind: kind + "-unreadable", ledger: ledger)
        }
        let old = Prefs.get(Store.key(kind, ledger), [Op]())
        if (try? save(old, ledger: ledger)) != nil { Prefs.d.removeObject(forKey: "ledger." + Store.key(kind, ledger)) }
        return old
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
