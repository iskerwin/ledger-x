import Foundation
import LedgerKit
import Security

/// where a ledger lives
enum SourceKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case github, gitlab, gitea, folder, webdav
    /// a folder of this app's own (On My iPhone › Ledger): the demo, and ledgers started on the phone
    case local
    var id: String { rawValue }
    /// what can be chosen when connecting (a ledger on the phone is made, not connected)
    static var connectable: [SourceKind] { allCases.filter { $0 != .local } }
    var name: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        case .gitea: return "Gitea"
        case .folder: return LS("文件夹")
        case .webdav: return "WebDAV"
        case .local: return LS("本机")
        }
    }
    var symbol: String {
        switch self {
        case .github, .gitlab, .gitea: return "arrow.triangle.branch"
        case .folder: return "folder"
        case .webdav: return "externaldrive.connected.to.line.below"
        case .local: return "iphone"
        }
    }
}

/// one ledger: where it is and how to reach it
struct RepoConfig: Codable, Hashable, Identifiable {
    var id = "default"
    var kind: SourceKind = .github
    var name = ""
    var owner = ""
    var repo = ""
    var branch = "main"
    var server = ""          // GitLab / Gitea base URL, or the WebDAV folder URL
    var username = ""        // WebDAV
    var bookmark: Data?      // folder: security-scoped bookmark
    var folderName = ""
    var token = ""           // token or password; kept in the Keychain, not in UserDefaults

    init() {}
    init(owner: String, repo: String, branch: String, token: String) {
        self.owner = owner; self.repo = repo; self.branch = branch; self.token = token
    }

    enum CodingKeys: String, CodingKey { case id, kind, name, owner, repo, branch, server, username, bookmark, folderName, token }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "default"
        kind = try c.decodeIfPresent(SourceKind.self, forKey: .kind) ?? .github
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? "main"
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
    }

    /// a server reached over plain http (allowed, for a server on the home network): the token and the ledger
    /// travel unencrypted, so the connection form says so
    var sendsInPlainText: Bool {
        [.gitlab, .gitea, .webdav].contains(kind) && server.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
    }

    var isComplete: Bool {
        switch kind {
        case .github: return !owner.isEmpty && !repo.isEmpty && !branch.isEmpty && !token.isEmpty
        case .gitlab, .gitea: return !server.isEmpty && !owner.isEmpty && !repo.isEmpty && !branch.isEmpty && !token.isEmpty
        case .folder: return bookmark != nil
        case .webdav: return URL(string: server)?.scheme != nil
        case .local: return !folderName.isEmpty
        }
    }

    /// shown in the ledger list
    var title: String {
        if !name.trimmed.isEmpty { return name.trimmed }
        switch kind {
        case .github, .gitlab, .gitea: return repo.isEmpty ? kind.name : repo
        case .folder: return folderName.isEmpty ? LS("文件夹") : folderName
        case .webdav: return URL(string: server)?.lastPathComponent.removingPercentEncoding ?? "WebDAV"
        case .local: return folderName
        }
    }
    var subtitle: String {
        switch kind {
        case .github: return "GitHub · \(owner)/\(repo) · \(branch)"
        case .gitlab, .gitea: return "\(kind.name) · \(URL(string: server)?.host ?? server) · \(owner)/\(repo)"
        case .folder: return LS("文件夹") + " · " + folderName
        case .webdav: return "WebDAV · " + (URL(string: server)?.host ?? server)
        case .local: return LS("本机 · 文件 › 我的 iPhone › Ledger X › %@", folderName)
        }
    }
    var keychainAccount: String { id == "default" ? "token" : "token." + id }
}

struct RepoTree: Codable, Equatable {
    var sha: String
    var files: [String: String]   // path -> blob sha
    var commit: String?
    /// the host can't refuse a write over a change made since it was read (a WebDAV server without strong ETags):
    /// two devices saving the same file at once, the later one wins
    var unguarded: Bool? = nil
}

struct GitHubError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? {
        switch status {
        case 401: return LS("凭据无效或已过期（401）")
        case 403: return LS("权限不足（403）：%@", message)
        case 404: return LS("未找到仓库、分支或路径（404）") + (message.isEmpty ? "" : LS("：") + message)
        case 409, 412, 422: return LS("远端文件已被修改（%@），稍后将自动重试", status)
        default: return "\(status) \(message)"
        }
    }
}

struct GitHub: LedgerBackend {
    let cfg: RepoConfig
    var repoPath: String { "/repos/\(cfg.owner)/\(cfg.repo)" }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, raw: Bool = false) async throws -> Data {
        guard let url = URL(string: "https://api.github.com" + path) else { throw GitHubError(status: 0, message: "bad url") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer " + cfg.token, forHTTPHeaderField: "Authorization")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue(raw ? "application/vnd.github.raw+json" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let body = body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await GitHub.session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
            throw GitHubError(status: status, message: msg)
        }
        return data
    }

    private func json(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let d = try await request(path, method: method, body: body)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? s }
    static func encPath(_ p: String) -> String { p.split(separator: "/", omittingEmptySubsequences: false).map { enc(String($0)) }.joined(separator: "/") }

    func fetchTree() async throws -> RepoTree {
        let t = try await json("\(repoPath)/git/trees/\(GitHub.enc(cfg.branch))?recursive=1")
        var files: [String: String] = [:]
        for n in (t["tree"] as? [[String: Any]]) ?? [] where n["type"] as? String == "blob" {
            if let p = n["path"] as? String, let s = n["sha"] as? String { files[p] = s }
        }
        let commit = try? await json("\(repoPath)/commits/\(GitHub.enc(cfg.branch))")["sha"] as? String
        return RepoTree(sha: t["sha"] as? String ?? "", files: files, commit: commit ?? nil)
    }

    func blob(_ sha: String) async throws -> String {
        let d = try await request("\(repoPath)/git/blobs/\(sha)", raw: true)
        return String(decoding: d, as: UTF8.self)
    }

    /// returns the new blob sha
    func putFile(_ path: String, text: String, sha: String?, message: String) async throws -> String {
        var body: [String: Any] = ["message": message, "content": Data(text.utf8).base64EncodedString(), "branch": cfg.branch]
        if let sha = sha { body["sha"] = sha }
        let r = try await json("\(repoPath)/contents/\(GitHub.encPath(path))", method: "PUT", body: body)
        return (r["content"] as? [String: Any])?["sha"] as? String ?? ""
    }

    func deleteFile(_ path: String, sha: String, message: String) async throws {
        _ = try await request("\(repoPath)/contents/\(GitHub.encPath(path))", method: "DELETE", body: ["message": message, "sha": sha, "branch": cfg.branch])
    }

    // LedgerBackend
    func read(_ path: String, version: String) async throws -> String { try await blob(version) }
    func write(_ path: String, text: String, version: String?, message: String) async throws -> String {
        try await putFile(path, text: text, sha: version, message: message)
    }
    func delete(_ path: String, version: String, message: String) async throws { try await deleteFile(path, sha: version, message: message) }

    /// several files as one commit through the Git data API: tree → commit → move the branch.
    /// Each file must still be at the version the change was made against, else 409 (refetch and retry).
    func writeMany(_ changes: [FileChange], message: String) async throws -> [String: String] {
        if changes.count <= 1 { return try await writeSequentially(changes, message: message) }
        let ref = try await json("\(repoPath)/git/ref/heads/\(GitHub.encPath(cfg.branch))")
        guard let head = (ref["object"] as? [String: Any])?["sha"] as? String else { throw GitHubError(status: 404, message: cfg.branch) }
        let commit = try await json("\(repoPath)/git/commits/\(head)")
        guard let baseTree = (commit["tree"] as? [String: Any])?["sha"] as? String else { throw GitHubError(status: 404, message: head) }
        let t = try await json("\(repoPath)/git/trees/\(baseTree)?recursive=1")
        var now: [String: String] = [:]
        for n in (t["tree"] as? [[String: Any]]) ?? [] where n["type"] as? String == "blob" {
            if let p = n["path"] as? String, let s = n["sha"] as? String { now[p] = s }
        }
        var entries: [[String: Any]] = []
        for c in changes {
            if now[c.path] != c.version { throw GitHubError(status: 409, message: c.path) }
            if let text = c.text {
                entries.append(["path": c.path, "mode": "100644", "type": "blob", "content": text])
            } else if c.version != nil {
                entries.append(["path": c.path, "mode": "100644", "type": "blob", "sha": NSNull()])
            }
        }
        if entries.isEmpty { return [:] }
        let tree = try await json("\(repoPath)/git/trees", method: "POST", body: ["base_tree": baseTree, "tree": entries])
        guard let treeSHA = tree["sha"] as? String else { throw GitHubError(status: 0, message: "tree") }
        let c = try await json("\(repoPath)/git/commits", method: "POST", body: ["message": message, "tree": treeSHA, "parents": [head]])
        guard let newCommit = c["sha"] as? String else { throw GitHubError(status: 0, message: "commit") }
        do {
            _ = try await json("\(repoPath)/git/refs/heads/\(GitHub.encPath(cfg.branch))", method: "PATCH", body: ["sha": newCommit, "force": false])
        } catch let e as GitHubError where e.status == 422 {
            throw GitHubError(status: 409, message: e.message)      // someone pushed in between
        }
        var out: [String: String] = [:]
        for c in changes { if let text = c.text { out[c.path] = gitBlobSHA(text) } }
        return out
    }
    func readData(_ path: String) async throws -> Data {
        try await request("\(repoPath)/contents/\(GitHub.encPath(path))?ref=\(GitHub.enc(cfg.branch))", raw: true)
    }
    func writeData(_ path: String, data: Data, message: String) async throws {
        _ = try await json("\(repoPath)/contents/\(GitHub.encPath(path))", method: "PUT",
                           body: ["message": message, "content": data.base64EncodedString(), "branch": cfg.branch])
    }
    func check() async -> CI? { await latestCheck() }
    func webURL(_ file: String, line: Int?) -> URL? {
        URL(string: "https://github.com/\(cfg.owner)/\(cfg.repo)/blob/\(cfg.branch)/\(GitHub.encPath(file))" + (line.map { "#L\($0)" } ?? ""))
    }
    var repoURL: URL? { URL(string: "https://github.com/\(cfg.owner)/\(cfg.repo)") }

    enum CIState: String, Codable { case ok, fail, running, empty, noperm, error }
    struct CI: Codable, Equatable { var state: CIState; var url: String?; var sha: String?; var at: String? }

    func latestCheck() async -> CI {
        do {
            let r = try await json("\(repoPath)/actions/workflows/bean-check.yml/runs?branch=\(GitHub.enc(cfg.branch))&per_page=1")
            guard let run = (r["workflow_runs"] as? [[String: Any]])?.first else { return CI(state: .empty) }
            let status = run["status"] as? String, concl = run["conclusion"] as? String
            let st: CIState = status != "completed" ? .running : concl == "success" ? .ok : .fail
            return CI(state: st, url: run["html_url"] as? String, sha: run["head_sha"] as? String, at: run["updated_at"] as? String)
        } catch let e as GitHubError {
            return CI(state: e.status == 404 ? .empty : e.status == 403 ? .noperm : .error)
        } catch { return CI(state: .error) }
    }
}

/// blobs by sha on disk (they never change). The text is also kept in memory, so a second read does not open the file.
enum BlobCache {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    private static let memory = TextMemo()
    /// git blob shas are used as they are; other version tokens (WebDAV ETags) are hashed into a file name
    static func name(_ key: String) -> String {
        key.count == 40 && key.allSatisfy({ $0.isHexDigit }) ? key : sha1Hex(Data(key.utf8))
    }
    static func get(_ sha: String) -> String? {
        if let text = memory.get(sha) { return text }
        guard let text = try? String(contentsOf: dir.appendingPathComponent(name(sha)), encoding: .utf8) else { return nil }
        memory.set(sha, text)
        return text
    }
    static func set(_ sha: String, _ text: String) {
        memory.set(sha, text)
        try? Data(text.utf8).write(to: dir.appendingPathComponent(name(sha)), options: .atomic)
    }
    /// true when this version is already in memory or the file is on disk, without reading the text
    static func contains(_ sha: String) -> Bool {
        memory.contains(sha) || FileManager.default.fileExists(atPath: dir.appendingPathComponent(name(sha)).path)
    }
    /// delete every cached version except `keep` (the files of each ledger's current tree): every commit
    /// leaves the previous version of the files it changed behind, and those are never read again
    static func prune(keep: Set<String>) {
        let names = Set(keep.map(name))
        memory.prune { names.contains(name($0)) }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in files where !names.contains(f) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
    }
    static func clear() {
        memory.clear()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

enum Keychain {
    static let service = "ledger.github"
    /// SecItemAdd; tests stand in a keychain that refuses, as a sideloaded build without a keychain group does
    static var add: (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Kept on this phone only: not carried to another device by a backup. When the keychain refuses (a sideloaded
    /// build without a keychain group), the token goes to a protected file of the app's own that backups leave out —
    /// never into the settings (UserDefaults), where it sat in plain text.
    static func save(_ value: String, account: String = "token") {
        SecItemDelete(base(account) as CFDictionary)
        var item = base(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if add(item as CFDictionary) == errSecSuccess {
            Fallback.remove(account)
        } else {
            Fallback.write(value, account)
        }
        UserDefaults.standard.removeObject(forKey: Fallback.legacyKey(account))
    }

    static func load(account: String = "token") -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let item = out as? [String: Any], let d = item[kSecValueData as String] as? Data {
            let v = String(decoding: d, as: UTF8.self)
            // saved before it was kept to this phone: saved again so a backup no longer carries it
            if (item[kSecAttrAccessible as String] as? String) != (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) { save(v, account: account) }
            return v
        }
        // outside the keychain (a file now, the settings before): moved in now if the keychain works
        guard let v = Fallback.read(account) ?? UserDefaults.standard.string(forKey: Fallback.legacyKey(account)) else { return nil }
        save(v, account: account)
        return v
    }

    /// a ledger removed: its token goes, from wherever it was kept
    static func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
        Fallback.remove(account)
        UserDefaults.standard.removeObject(forKey: Fallback.legacyKey(account))
    }

    /// the token could not go into the keychain and sits in the app's protected file instead
    static func inFallback(account: String = "token") -> Bool {
        !(Fallback.read(account) ?? "").isEmpty
    }

    /// Application Support/Credentials: file protection until first unlock, excluded from backups
    enum Fallback {
        static func legacyKey(_ account: String) -> String { "ledger.fallback." + account }

        static func url(_ account: String) -> URL? {
            guard var dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Credentials", isDirectory: true) else { return nil }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var keep = URLResourceValues()
            keep.isExcludedFromBackup = true
            try? dir.setResourceValues(keep)
            return dir.appendingPathComponent(account.replacingOccurrences(of: "/", with: "_"))
        }

        static func write(_ value: String, _ account: String) {
            guard let u = url(account) else { return }
            try? Data(value.utf8).write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }

        static func read(_ account: String) -> String? {
            guard let u = url(account), let d = try? Data(contentsOf: u) else { return nil }
            return String(decoding: d, as: UTF8.self)
        }

        static func remove(_ account: String) {
            if let u = url(account) { try? FileManager.default.removeItem(at: u) }
        }
    }
}
