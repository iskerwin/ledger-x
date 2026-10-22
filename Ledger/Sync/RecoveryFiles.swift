import Foundation
import CryptoKit

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
