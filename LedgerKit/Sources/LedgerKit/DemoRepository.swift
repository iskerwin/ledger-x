import Foundation

/// The public demo repository is the single source of sample data. No credentials or Git history
/// are needed: resolve main once, then read every file from that immutable commit.
public enum DemoRepository {
    public static let repository = "iskerwin/ledger-demo"
    public typealias Read = (URL) async throws -> Data

    private struct Commit: Decodable { let sha: String }
    private struct Tree: Decodable {
        let truncated: Bool
        let tree: [File]
        struct File: Decodable {
            let path: String
            let type: String
            let mode: String
            let size: Int?
        }
    }

    public enum Failure: LocalizedError {
        case invalidSnapshot
        case invalidLedger(String)
        case http(Int)
        public var errorDescription: String? {
            switch self {
            case .invalidSnapshot: return tr("演示数据不完整，请稍后重试", "The demo snapshot is incomplete. Please try again later.")
            case .invalidLedger(let message): return tr("演示账本校验失败：", "Demo validation failed: ") + message
            case .http(let status): return tr("下载演示账本失败（", "Demo download failed (") + "\(status))"
            }
        }
    }

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Ledger-X-Demo", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidSnapshot }
        guard response.statusCode == 200 else { throw Failure.http(response.statusCode) }
        return data
    }

    private static func isLedgerFile(_ path: String) -> Bool {
        path.hasSuffix(".bean") || path.hasSuffix(".beancount") || path.hasSuffix(".bql") || path == "ledger-x.json"
    }

    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && !$0.hasPrefix(".")
            }
    }

    public static func files(read: Read? = nil) async throws -> [String: Data] {
        let request = read ?? download
        let decoder = JSONDecoder()
        let commit = try decoder.decode(Commit.self, from: await request(URL(string: "https://api.github.com/repos/\(repository)/commits/main")!))
        guard commit.sha.count == 40, commit.sha.allSatisfy({ $0.isHexDigit }) else { throw Failure.invalidSnapshot }
        let tree = try decoder.decode(Tree.self, from: await request(URL(string: "https://api.github.com/repos/\(repository)/git/trees/\(commit.sha)?recursive=1")!))
        let selected = tree.tree.filter { isLedgerFile($0.path) }
        guard !tree.truncated, !selected.isEmpty, selected.count <= 100,
              Set(selected.map(\.path)).count == selected.count,
              selected.allSatisfy({ safePath($0.path) && $0.type == "blob" && $0.mode == "100644" && (0...2_000_000).contains($0.size ?? -1) }),
              selected.contains(where: { $0.path == "main.bean" }) else { throw Failure.invalidSnapshot }
        var files: [String: Data] = [:]
        var total = 0
        for file in selected.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let path = file.path.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%")))!
            }.joined(separator: "/")
            let data = try await request(URL(string: "https://raw.githubusercontent.com/\(repository)/\(commit.sha)/\(path)")!)
            total += data.count
            guard data.count == file.size, total <= 10_000_000, String(data: data, encoding: .utf8) != nil else { throw Failure.invalidSnapshot }
            files[file.path] = data
        }
        if let config = files["ledger-x.json"] {
            guard (try JSONSerialization.jsonObject(with: config)) is [String: Any] else { throw Failure.invalidSnapshot }
        }
        let ledger = loadLedger(root: "main.bean", listFiles: { Array(files.keys) }) { path in
            guard let data = files[path], let text = String(data: data, encoding: .utf8) else { throw Failure.invalidSnapshot }
            return text
        }
        guard !ledger.txns.isEmpty else { throw Failure.invalidSnapshot }
        if let error = ledger.errors.first(where: { !$0.soft }) { throw Failure.invalidLedger(error.msg) }
        return files
    }

    /// An existing local demo works offline and keeps edits. Reset downloads and validates in full
    /// before replacing it; a failed download never removes the user's previous copy.
    public static func install(at destination: URL, reset: Bool = false, read: Read? = nil) async throws {
        let fm = FileManager.default
        if !reset && fm.fileExists(atPath: destination.appendingPathComponent("main.bean").path) { return }
        let files = try await files(read: read)
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".demo-download-" + UUID().uuidString)
        let backup = parent.appendingPathComponent(".demo-backup-" + UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        for (path, data) in files {
            let file = stage.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
        try Task.checkCancellation()
        let existed = fm.fileExists(atPath: destination.path)
        if existed { try fm.moveItem(at: destination, to: backup) }
        do {
            try fm.moveItem(at: stage, to: destination)
        } catch {
            if existed { try? fm.moveItem(at: backup, to: destination) }
            throw error
        }
        if existed { try? fm.removeItem(at: backup) }
    }
}
