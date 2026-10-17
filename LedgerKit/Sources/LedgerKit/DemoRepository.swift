import Foundation

/// The public demo repository is the single source of sample data. A copy of it goes into the app when it is
/// built (Ledger/Demo, fetched by CI), so the demo opens at once and offline; later versions are fetched from the
/// repository without reinstalling the app. No credentials or Git history are needed: resolve main once, then read
/// every file from that commit, from GitHub or from the app's Cloudflare mirror of the same commits.
public enum DemoRepository {
    public static let repository = "iskerwin/ledger-demo"
    public typealias Read = (URL) async throws -> Data

    /// where the files come from: GitHub itself, or the mirror (tools/cloudflare/worker.js), which serves the same
    /// commits where GitHub can't be reached
    public enum Source: Equatable {
        case github
        case mirror(URL)

        func commitURL() -> URL {
            switch self {
            case .github: return URL(string: "https://api.github.com/repos/\(DemoRepository.repository)/commits/main")!
            case .mirror(let base): return base.appendingPathComponent("demo/commit")
            }
        }
        func treeURL(_ sha: String) -> URL {
            switch self {
            case .github: return URL(string: "https://api.github.com/repos/\(DemoRepository.repository)/git/trees/\(sha)?recursive=1")!
            case .mirror(let base): return base.appendingPathComponent("demo/tree/\(sha)")
            }
        }
        /// `path` already percent-encoded, segment by segment
        func rawURL(_ sha: String, _ path: String) -> URL {
            switch self {
            case .github: return URL(string: "https://raw.githubusercontent.com/\(DemoRepository.repository)/\(sha)/\(path)")!
            case .mirror(let base): return URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/demo/raw/\(sha)/\(path)")!
            }
        }
    }

    /// the files of one commit of the demo
    public struct Snapshot: Equatable {
        public let commit: String
        public let files: [String: Data]
    }

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
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Ledger-X-Demo", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidSnapshot }
        guard response.statusCode == 200 else { throw Failure.http(response.statusCode) }
        return data
    }

    static func isLedgerFile(_ path: String) -> Bool {
        path.hasSuffix(".bean") || path.hasSuffix(".beancount") || path.hasSuffix(".bql") || path == "ledger-x.json"
    }

    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && !$0.hasPrefix(".")
            }
    }

    static func isCommit(_ s: String) -> Bool { s.count == 40 && s.allSatisfy { $0.isHexDigit } }

    /// each source in turn until one answers (the error of the last one otherwise)
    private static func firstAnswer<T>(_ sources: [Source], _ body: (Source) async throws -> T) async throws -> T {
        var last: Error = Failure.invalidSnapshot
        for source in sources {
            do { return try await body(source) }
            catch is CancellationError { throw CancellationError() }
            catch { last = error }
        }
        throw last
    }

    /// the commit main points at now
    public static func latestCommit(sources: [Source] = [.github], read: Read? = nil) async throws -> String {
        let request = read ?? download
        return try await firstAnswer(sources) { source in
            let sha = try JSONDecoder().decode(Commit.self, from: await request(source.commitURL())).sha
            guard isCommit(sha) else { throw Failure.invalidSnapshot }
            return sha
        }
    }

    /// every ledger file of a commit (main's latest when none is given), checked as a whole: complete, safe paths,
    /// sizes as listed, and a ledger that loads without errors
    public static func snapshot(commit: String? = nil, sources: [Source] = [.github], read: Read? = nil) async throws -> Snapshot {
        let request = read ?? download
        return try await firstAnswer(sources) { source in
            let sha: String
            if let c = commit { sha = c } else { sha = try JSONDecoder().decode(Commit.self, from: await request(source.commitURL())).sha }
            guard isCommit(sha) else { throw Failure.invalidSnapshot }
            let tree = try JSONDecoder().decode(Tree.self, from: await request(source.treeURL(sha)))
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
                let data = try await request(source.rawURL(sha, path))
                total += data.count
                guard data.count == file.size, total <= 10_000_000 else { throw Failure.invalidSnapshot }
                files[file.path] = data
            }
            try validate(files)
            return Snapshot(commit: sha, files: files)
        }
    }

    /// the files make a ledger: text, ledger-x.json an object, main.bean loading with transactions and no errors
    static func validate(_ files: [String: Data]) throws {
        guard files["main.bean"] != nil, files.values.allSatisfy({ String(data: $0, encoding: .utf8) != nil }) else { throw Failure.invalidSnapshot }
        if let config = files["ledger-x.json"] {
            guard (try? JSONSerialization.jsonObject(with: config)) is [String: Any] else { throw Failure.invalidSnapshot }
        }
        let ledger = loadLedger(root: "main.bean", listFiles: { Array(files.keys) }) { path in
            guard let data = files[path], let text = String(data: data, encoding: .utf8) else { throw Failure.invalidSnapshot }
            return text
        }
        guard !ledger.txns.isEmpty else { throw Failure.invalidSnapshot }
        if let error = ledger.errors.first(where: { !$0.soft }) { throw Failure.invalidLedger(error.msg) }
    }

    /// the ledger files of a folder (the copy built into the app), checked like a download
    public static func folderFiles(_ folder: URL) throws -> [String: Data] {
        let fm = FileManager.default
        guard let paths = fm.subpaths(atPath: folder.path) else { throw Failure.invalidSnapshot }
        var files: [String: Data] = [:]
        for p in paths where isLedgerFile(p) && safePath(p) {
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: folder.appendingPathComponent(p).path, isDirectory: &dir), !dir.boolValue else { continue }
            files[p] = try Data(contentsOf: folder.appendingPathComponent(p))
        }
        try validate(files)
        return files
    }

    /// An existing local demo works offline and keeps edits; without one (or with `reset`) the latest snapshot is
    /// downloaded and checked in full before it replaces anything. The commit installed, or nil when the copy there
    /// was kept.
    @discardableResult
    public static func install(at destination: URL, reset: Bool = false, commit: String? = nil,
                               sources: [Source] = [.github], read: Read? = nil) async throws -> String? {
        if !reset && FileManager.default.fileExists(atPath: destination.appendingPathComponent("main.bean").path) { return nil }
        let s = try await snapshot(commit: commit, sources: sources, read: read)
        try Task.checkCancellation()
        try put(s.files, at: destination)
        return s.commit
    }

    /// `files` in place of whatever is at `destination`: written beside it first, then swapped in, so a failure
    /// leaves the previous copy as it was
    public static func put(_ files: [String: Data], at destination: URL) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".demo-download-" + UUID().uuidString)
        let backup = parent.appendingPathComponent(".demo-backup-" + UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        for (path, data) in files {
            guard safePath(path) else { throw Failure.invalidSnapshot }
            let file = stage.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
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
